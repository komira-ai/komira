# =============================================================================
# src/komira_http_client/objectstore_http.mojo — ObjectStoreHttp seam
# =============================================================================
#
# The client exposes a small ObjectStoreHttp-shaped trait so
# komira_objectstore is decoupled from the exact HttpClient API.
# ObjectStoreHttp supersedes and replaces an ObjectStore
# HttpTransport trait — it does not merely rename it.
#
# Three substantive shapes:
#   1. `head(url)`        → returns ObjectMetadata (Content-Length, ETag,
#                            content-type, last-modified, status)
#   2. `get_range(url, start, end)` → returns ClientResponse with
#                            the requested byte range as the body
#                            (HTTP 206 Partial Content). Already
#                            exists at HttpClient.get_range.
#                            Here exposed via the ObjectStoreHttp seam.
#   3. `get_ranges(url, ranges, max_concurrency)` →
#                            FAN-OUT: N concurrent range requests via
#                            Today: sequential h1 fan-out — h2 multiplex
#                            sequential h1 fan-out — h2 multiplex
#                            is a follow-up (requires the pool reuse
#                            wiring on HttpClient.send for h2).
# The production target signature for get_ranges takes a caller-
# The production target signature for get_ranges takes a caller-
# `get_ranges` itself returns a simpler `RangeFanoutResult` (= List of
# ClientResponse per range); the scatter-write form is `get_ranges_into`.
#
# Provider-agnostic / signing-agnostic disclaimer.
#
# Encapsulation discipline:
#   * ZERO UnsafePointer in any signature.
#   * ZERO wildcard origins.
#   * ZERO `unsafe_from_address`.
#   * ZERO `take_pointee`.
#   * ZERO new ArcPointer.
# =============================================================================

from std.memory import unsafe_memcpy

from komira_async.cancellation.token import CancellationToken
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime
from komira_collections.slab import Slab

from komira_http_client.body import EmptyBody
from komira_http_client.client import HttpClient, build_get_request, build_head_request
from komira_http_client.error import HttpError
from komira_http_client.header_map import HeaderMap, sab_to_string
from komira_http_client.response_body import BufferedResponseBody
from komira_http_client.service import ClientRequest, HttpService
from komira_http_client.state_machine import ClientResponse
from komira_http_client.url import Url
from komira_http_core.codec.types import HttpMethod
from komira_http_core.transport.io_stream import Connector


# =============================================================================
# §1 — ByteRange + ObjectMetadata.
# =============================================================================


@fieldwise_init
struct ByteRange(
    Copyable, ImplicitlyCopyable, Movable, Deinitable,
):
    """A half-open [start, end) byte range. `end = -1` means
    open-ended (read to EOF)."""

    var start: Int64
    var end: Int64

    @staticmethod
    def closed(start: Int64, end: Int64) -> ByteRange:
        return ByteRange(start=start, end=end)

    @staticmethod
    def open(start: Int64) -> ByteRange:
        return ByteRange(start=start, end=Int64(-1))


struct ObjectMetadata(Movable, Deinitable):
    """Object metadata extracted from a HEAD response.

    Fields:
      status              — HTTP status code (typically 200 for HEAD success)
      content_length      — Content-Length value; -1 if absent
      content_type        — Content-Type value; empty if absent
      etag                — ETag value; empty if absent
      last_modified       — Last-Modified value; empty if absent
    """

    var status: Int
    var content_length: Int64
    var content_type: String
    var etag: String
    var last_modified: String

    @staticmethod
    def from_response(
        status: Int, ref headers: HeaderMap,
    ) -> ObjectMetadata:
        # Option C migration:
        #   * Content-Length: `get_int64` parses directly from value bytes,
        #     skipping the per-call String materialization that the old
        #     `Int(headers.get("Content-Length").value())` path paid.
        #   * Content-Type / ETag / Last-Modified: ObjectMetadata stores
        #     these as Strings — we still materialize one each but via
        #     `get_view` + `sab_to_string`, which lets future consumers
        #     reach the SAB directly. The boundary alloc count is
        #     unchanged (1 per field that was present), but the
        #     intermediate Optional[String] step is gone.
        var cl_int_opt = headers.get_int64(String("Content-Length"))
        var content_length = cl_int_opt.value() if cl_int_opt.__bool__() else Int64(-1)
        var content_type = String()
        var ct_opt = headers.get_view(String("Content-Type"))
        if ct_opt.__bool__():
            content_type = sab_to_string(ct_opt.value())
        var etag = String()
        var etag_opt = headers.get_view(String("ETag"))
        if etag_opt.__bool__():
            etag = sab_to_string(etag_opt.value())
        var last_modified = String()
        var lm_opt = headers.get_view(String("Last-Modified"))
        if lm_opt.__bool__():
            last_modified = sab_to_string(lm_opt.value())
        return ObjectMetadata(
            status=status,
            content_length=content_length,
            content_type=content_type^,
            etag=etag^,
            last_modified=last_modified^,
        )

    def __init__(
        out self,
        status: Int,
        content_length: Int64,
        var content_type: String,
        var etag: String,
        var last_modified: String,
    ):
        self.status = status
        self.content_length = content_length
        self.content_type = content_type^
        self.etag = etag^
        self.last_modified = last_modified^


# =============================================================================
# §2 — RangeFanoutResult — outcome of a get_ranges call.
# =============================================================================


struct RangeFanoutResult(Movable, Deinitable):
    """The list of responses corresponding to each range in the
    request batch. responses[i] corresponds to ranges[i].

    Each response is a BufferedResponseBody — the range's bytes are
    in `responses[i].body.bytes()`.

    `get_ranges_into` is the scatter-write
    production shape (into caller-supplied
    ByteView[mut=True] + dst_offsets)."""

    var responses: Slab[ClientResponse[BufferedResponseBody]]

    @staticmethod
    def new(var responses: Slab[ClientResponse[BufferedResponseBody]]) -> RangeFanoutResult:
        return RangeFanoutResult(responses=responses^)

    def __init__(
        out self,
        var responses: Slab[ClientResponse[BufferedResponseBody]],
    ):
        self.responses = responses^

    def count(self) -> Int:
        return self.responses.len()


# =============================================================================
# §3 — ObjectStoreHttp trait.
# =============================================================================


trait ObjectStoreHttp(Movable, Deinitable):
    """ ObjectStoreHttp seam — the request-shaped byte-moving
    seam komira_objectstore codes against.

    Provider-agnostic + signing-agnostic — disclaimer.
    The `url` passed in is already endpoint-resolved; the request
    headers (incl. SigV4 / GCS HMAC / Azure SharedKey signature) are
    already populated by an objectstore-side SigningLayer.

    Three methods:
      * head: returns ObjectMetadata
      * get_range: returns a buffered partial-body response
      * get_ranges: fan-out N concurrent range requests

    All take a Runtime parameter + Reactor + CancellationToken per
    the explicit-runtime-passing pattern."""

    def head[RT: Runtime](
        mut self,
        var url: Url,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ObjectMetadata:
        ...

    def get_range[RT: Runtime](
        mut self,
        var url: Url,
        start: Int64,
        end: Int64,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[BufferedResponseBody]:
        ...

    def get_ranges[RT: Runtime](
        mut self,
        var url: Url,
        var ranges: List[ByteRange],
        max_concurrency: Int,
        mut reactor: Reactor[RT.Sink],
    ) raises -> RangeFanoutResult:
        ...

    def get_ranges_into[RT: Runtime, O: Origin[mut=True]](
        mut self,
        var url: Url,
        var ranges: List[ByteRange],
        dst: Span[UInt8, O],
        var dst_offsets: List[Int],
        max_concurrency: Int,
        mut reactor: Reactor[RT.Sink],
    ) raises:
        """Scatter-write fan-out. For each `range[i]` (which
        MUST have `end >= 0` — closed half-open), dispatch a GET with
        Range: header and write the response bytes into
        `dst[dst_offsets[i] : dst_offsets[i] + (range[i].end - range[i].start + 1)]`.

        Caller pre-allocates `dst` large enough to hold all ranges'
        bytes; `dst_offsets[i]` is the destination offset for ranges[i].

        Raises HttpError[URL_INVALID] if any range has end < 0
        (open-ended ranges are not supported — caller must first HEAD
        to learn the content length).
        """
        ...


# =============================================================================
# §4 — HttpClientObjectStoreHttp[C] — the production conformer.
# =============================================================================
#
# Wraps an HttpClient[C] and adapts its surface to ObjectStoreHttp.
# h1 sequential fan-out for get_ranges; h2 multiplex
# (requires HttpClient pool-reuse-across-send-calls — the field
# refactor is the substrate; production wiring of checkout/checkin is
# a follow-up).


struct HttpClientObjectStoreHttp[C: Connector](
    ObjectStoreHttp, Movable, Deinitable,
):
    """ObjectStoreHttp conformer backed by HttpClient[C].

    Construction:
      `HttpClientObjectStoreHttp.wrap(client)`.

    The `client` is consumed by-value; the conformer owns it. For
    ObjectStore use, construct one HttpClientObjectStoreHttp per
    worker."""

    var _client: HttpClient[Self.C]

    @staticmethod
    def wrap(var client: HttpClient[Self.C]) -> HttpClientObjectStoreHttp[Self.C]:
        return HttpClientObjectStoreHttp[Self.C](_client=client^)

    def __init__(out self, var _client: HttpClient[Self.C]):
        self._client = _client^

    def head[RT: Runtime](
        mut self,
        var url: Url,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ObjectMetadata:
        """Issue a HEAD request, return ObjectMetadata extracted from
        response headers."""
        var headers = HeaderMap()
        var req = build_head_request(url^, headers^)
        var resp = self._client.send_buffered[RT, EmptyBody](req^, reactor)
        return ObjectMetadata.from_response(Int(resp.status), resp.headers)

    def get_range[RT: Runtime](
        mut self,
        var url: Url,
        start: Int64,
        end: Int64,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[BufferedResponseBody]:
        """Issue a GET with `Range: bytes=start-end` header (or
        `bytes=start-` if end < 0). Returns a buffered response.

        Note: this conformer uses send_buffered (not the streaming
        send) because ObjectStoreHttp's seam is buffered — the
        ObjectStore reader buffers its bytes per-chunk anyway."""
        var range_value = String("bytes=") + String(Int(start)) + String("-")
        if end >= Int64(0):
            range_value = range_value + String(Int(end))
        var hdrs = HeaderMap()
        hdrs.append(String("Range"), range_value^)
        var req = build_get_request(url^, hdrs^)
        var resp = self._client.send_buffered[RT, EmptyBody](req^, reactor)
        return resp^

    def get_ranges[RT: Runtime](
        mut self,
        var url: Url,
        var ranges: List[ByteRange],
        max_concurrency: Int,
        mut reactor: Reactor[RT.Sink],
    ) raises -> RangeFanoutResult:
        """Sequential h1 fan-out — issues each range request
        in order via separate send_buffered calls. Returns a
        RangeFanoutResult with responses[i] corresponding to ranges[i].

        h2 multiplex (once the HttpClient pool-reuse-across-
        send is wired) so N concurrent range requests share one TCP
        conn via h2 streams — fd-count=1.

        limitation: `max_concurrency` is currently ignored (h1
        sequential is one-at-a-time). Document as a follow-up."""
        var n = ranges.__len__()
        var responses = Slab[ClientResponse[BufferedResponseBody]]()
        var i = 0
        while i < n:
            var r = ranges[i]
            var url_copy = _clone_url_local(url)
            var resp = self.get_range[RT](
                url_copy^, r.start, r.end, reactor,
            )
            responses.append(resp^)
            i = i + 1
        return RangeFanoutResult.new(responses^)

    def get_ranges_into[RT: Runtime, O: Origin[mut=True]](
        mut self,
        var url: Url,
        var ranges: List[ByteRange],
        dst: Span[UInt8, O],
        var dst_offsets: List[Int],
        max_concurrency: Int,
        mut reactor: Reactor[RT.Sink],
    ) raises:
        """Scatter-write per-range responses into `dst` at the
        offsets given by `dst_offsets`.

        Production conformer: issues each Range request via
        self._client.send_buffered and `memcpy`s the response bytes
        into the dst Span. v1 uses sequential h1; full h2 multiplex
        across the SAME conn (the load-bearing fd-count=1 invariant for
        ObjectStore range fan-out) comes once h2 send_buffered
        wiring lands at the H2ClientPool layer.

        The `max_concurrency` argument is reserved for the h2 multiplex
        upgrade — v1 ignores it (h1 is sequential one-at-a-time).
        """
        var n = ranges.__len__()
        if dst_offsets.__len__() != n:
            raise Error(
                "HttpError[URL_INVALID]: dst_offsets length "
                + String(dst_offsets.__len__())
                + " != ranges length " + String(n)
            )
        var i = 0
        while i < n:
            var r = ranges[i]
            if r.end < Int64(0):
                raise Error(
                    "HttpError[URL_INVALID]: get_ranges_into requires"
                    " closed ranges (end >= 0); range[" + String(i)
                    + "] has end=-1"
                )
            var url_copy = _clone_url_local(url)
            var resp = self.get_range[RT](
                url_copy^, r.start, r.end, reactor,
            )
            # Scatter-write: response body bytes -> dst[offset:offset+n].
            ref body_bytes = resp.body.bytes_ref()
            var body_n = body_bytes.__len__()
            var dst_off = dst_offsets[i]
            if dst_off < 0 or dst_off + body_n > dst.__len__():
                raise Error(
                    "HttpError[URL_INVALID]: dst_offsets[" + String(i)
                    + "]=" + String(dst_off)
                    + " + body_len=" + String(body_n)
                    + " exceeds dst capacity=" + String(dst.__len__())
                )
            # SAFETY: byte-wise copy from response body (owned List[UInt8])
            # into caller-supplied dst (Span[UInt8, O:mut=True]). Both
            # pointers are valid for the method-frame; the caller holds
            # `dst`'s underlying storage live across the call. Internal
            # UnsafePointer use is allowed per pointer-hierarchy item 4 — public
            # signature carries only Span/refs.
            var dst_ptr = dst.unsafe_ptr() + dst_off
            var src_ptr = body_bytes.unsafe_ptr()
            unsafe_memcpy(dest=dst_ptr, src=src_ptr, count=body_n)
            i = i + 1


def _clone_url_local(ref src: Url) -> Url:
    """Deep-copy a Url (self-contained helper — same shape as
    retry.mojo's _clone_url)."""
    var out = Url(
        scheme=String(src.scheme),
        host=String(src.host),
        port=src.port,
        path=String(src.path),
    )
    out.userinfo = String(src.userinfo)
    out.query = String(src.query)
    out.fragment = String(src.fragment)
    return out^


# =============================================================================
# §5 — ScriptedObjectStoreHttp — test conformer.
# =============================================================================
#
# (the ScriptedConnector test pattern), the
# ObjectStoreHttp seam needs a deterministic-canned-response test
# conformer for unit tests that don't want real HttpClient wiring.
#
# Scripted entries are a Dict-like map of (URL, method) → canned
# response. Tests pre-populate; the conformer returns scripted on
# each call.


struct _ScriptedEntry(Movable, Deinitable):
    var url_str: String
    var method_name: String
    var status: Int
    var content_length: Int64
    var content_type: String
    var etag: String
    var last_modified: String
    var body: List[UInt8]

    @staticmethod
    def new(
        var url_str: String,
        var method_name: String,
        status: Int,
        content_length: Int64,
        var content_type: String,
        var etag: String,
        var last_modified: String,
        var body: List[UInt8],
    ) -> _ScriptedEntry:
        return _ScriptedEntry(
            url_str=url_str^,
            method_name=method_name^,
            status=status,
            content_length=content_length,
            content_type=content_type^,
            etag=etag^,
            last_modified=last_modified^,
            body=body^,
        )

    def __init__(
        out self,
        var url_str: String,
        var method_name: String,
        status: Int,
        content_length: Int64,
        var content_type: String,
        var etag: String,
        var last_modified: String,
        var body: List[UInt8],
    ):
        self.url_str = url_str^
        self.method_name = method_name^
        self.status = status
        self.content_length = content_length
        self.content_type = content_type^
        self.etag = etag^
        self.last_modified = last_modified^
        self.body = body^


struct ScriptedObjectStoreHttp(
    ObjectStoreHttp, Movable, Deinitable,
):
    """Test conformer for ObjectStoreHttp — returns canned responses
    per (URL, method) lookup. Used by Tier-2 tests that exercise the
    ObjectStoreHttp seam without an HttpClient.

    Construction:
      `ScriptedObjectStoreHttp.new()` — empty script.
      Pre-populate via `.add_head(url, metadata, body)` /
      `.add_get_range(url, response)`.

    Lookup: linear scan over entries (test code; correctness >> O(log N))."""

    var _entries: Slab[_ScriptedEntry]
    var _call_count: Int

    @staticmethod
    def new() -> ScriptedObjectStoreHttp:
        return ScriptedObjectStoreHttp(
            _entries=Slab[_ScriptedEntry](), _call_count=0,
        )

    def __init__(
        out self,
        var _entries: Slab[_ScriptedEntry],
        _call_count: Int,
    ):
        self._entries = _entries^
        self._call_count = _call_count

    def call_count(self) -> Int:
        """Diagnostic: how many calls (across head/get_range/get_ranges)
        the conformer has serviced. get_ranges counts as N calls (one
        per range)."""
        return self._call_count

    def add_head_response(
        mut self,
        url_str: String,
        status: Int,
        content_length: Int64,
        content_type: String,
        etag: String,
        last_modified: String,
    ):
        """Pre-populate a HEAD response for `url_str`."""
        var empty_body = List[UInt8]()
        self._entries.append(
            _ScriptedEntry.new(
                url_str=String(url_str),
                method_name=String("HEAD"),
                status=status,
                content_length=content_length,
                content_type=String(content_type),
                etag=String(etag),
                last_modified=String(last_modified),
                body=empty_body^,
            )
        )

    def add_get_range_response(
        mut self,
        url_str: String,
        status: Int,
        var body: List[UInt8],
    ):
        """Pre-populate a GET (with Range:) response for `url_str`."""
        var cl = Int64(body.__len__())
        self._entries.append(
            _ScriptedEntry.new(
                url_str=String(url_str),
                method_name=String("GET"),
                status=status,
                content_length=cl,
                content_type=String(),
                etag=String(),
                last_modified=String(),
                body=body^,
            )
        )

    def _lookup_idx(self, url_str: String, method_name: String) -> Int:
        var n = self._entries.len()
        var i = 0
        while i < n:
            if (
                self._entries[i].url_str == url_str
                and self._entries[i].method_name == method_name
            ):
                return i
            i = i + 1
        return -1

    def head[RT: Runtime](
        mut self,
        var url: Url,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ObjectMetadata:
        self._call_count = self._call_count + 1
        var url_str = _url_string_local(url)
        var idx = self._lookup_idx(url_str, String("HEAD"))
        if idx < 0:
            raise Error(
                "HttpError[CONNECT_FAILED]: no scripted HEAD entry for "
                + url_str
            )
        ref e = self._entries[idx]
        return ObjectMetadata(
            status=e.status,
            content_length=e.content_length,
            content_type=String(e.content_type),
            etag=String(e.etag),
            last_modified=String(e.last_modified),
        )

    def get_range[RT: Runtime](
        mut self,
        var url: Url,
        start: Int64,
        end: Int64,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[BufferedResponseBody]:
        self._call_count = self._call_count + 1
        var url_str = _url_string_local(url)
        var idx = self._lookup_idx(url_str, String("GET"))
        if idx < 0:
            raise Error(
                "HttpError[CONNECT_FAILED]: no scripted GET entry for "
                + url_str
            )
        # Slice body to [start, end] for the range request.
        ref full_body = self._entries[idx].body
        var n = Int64(full_body.__len__())
        var actual_end = end if end >= Int64(0) else n - Int64(1)
        if actual_end >= n:
            actual_end = n - Int64(1)
        var actual_start = start
        if actual_start < Int64(0):
            actual_start = Int64(0)
        var slice_bytes = List[UInt8]()
        var i = Int(actual_start)
        var stop = Int(actual_end) + 1
        while i < stop:
            slice_bytes.append(full_body[i])
            i = i + 1
        var resp_body = BufferedResponseBody.from_bytes(slice_bytes^)
        var resp = ClientResponse[BufferedResponseBody](resp_body^)
        var status_int: Int = self._entries[idx].status
        resp.status = Int32(status_int)
        resp.reason = String("Scripted")
        resp.headers = HeaderMap()
        resp.connection_close = False
        return resp^

    def get_ranges[RT: Runtime](
        mut self,
        var url: Url,
        var ranges: List[ByteRange],
        max_concurrency: Int,
        mut reactor: Reactor[RT.Sink],
    ) raises -> RangeFanoutResult:
        var n = ranges.__len__()
        var responses = Slab[ClientResponse[BufferedResponseBody]]()
        var i = 0
        while i < n:
            var r = ranges[i]
            var url_copy = _clone_url_local(url)
            var resp = self.get_range[RT](
                url_copy^, r.start, r.end, reactor,
            )
            responses.append(resp^)
            i = i + 1
        return RangeFanoutResult.new(responses^)

    def get_ranges_into[RT: Runtime, O: Origin[mut=True]](
        mut self,
        var url: Url,
        var ranges: List[ByteRange],
        dst: Span[UInt8, O],
        var dst_offsets: List[Int],
        max_concurrency: Int,
        mut reactor: Reactor[RT.Sink],
    ) raises:
        """ScriptedObjectStoreHttp conformer. Same scatter-write
        semantics as the production HttpClientObjectStoreHttp: per-range
        get_range + memcpy into dst at the supplied offsets.
        """
        var n = ranges.__len__()
        if dst_offsets.__len__() != n:
            raise Error(
                "HttpError[URL_INVALID]: dst_offsets length "
                + String(dst_offsets.__len__())
                + " != ranges length " + String(n)
            )
        var i = 0
        while i < n:
            var r = ranges[i]
            if r.end < Int64(0):
                raise Error(
                    "HttpError[URL_INVALID]: get_ranges_into requires"
                    " closed ranges (end >= 0); range[" + String(i)
                    + "] has end=-1"
                )
            var url_copy = _clone_url_local(url)
            var resp = self.get_range[RT](
                url_copy^, r.start, r.end, reactor,
            )
            ref body_bytes = resp.body.bytes_ref()
            var body_n = body_bytes.__len__()
            var dst_off = dst_offsets[i]
            if dst_off < 0 or dst_off + body_n > dst.__len__():
                raise Error(
                    "HttpError[URL_INVALID]: dst_offsets[" + String(i)
                    + "]=" + String(dst_off)
                    + " + body_len=" + String(body_n)
                    + " exceeds dst capacity=" + String(dst.__len__())
                )
            # SAFETY: same as HttpClientObjectStoreHttp.get_ranges_into.
            # ScriptedObjectStoreHttp's get_range returns a fresh List[UInt8]
            # body; we memcpy it into the caller-supplied dst Span before
            # the per-iter resp drops.
            var dst_ptr = dst.unsafe_ptr() + dst_off
            var src_ptr = body_bytes.unsafe_ptr()
            unsafe_memcpy(dest=dst_ptr, src=src_ptr, count=body_n)
            i = i + 1


def _url_string_local(ref u: Url) -> String:
    """Build canonical scheme://host[:port]/path[?query] string."""
    var out = String(u.scheme) + String("://")
    out = out + String(u.host)
    var port_val = u.effective_port()
    var default_port: UInt16 = UInt16(443) if u.is_https() else UInt16(80)
    if port_val != default_port:
        out = out + String(":") + String(Int(port_val))
    out = out + String(u.path)
    if u.query.byte_length() > 0:
        out = out + String("?") + String(u.query)
    return out^
