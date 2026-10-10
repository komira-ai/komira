# =============================================================================
# komira_azure_blob/azure.mojo — AzureStore (HttpService-backed Blob store)
# =============================================================================
#
# Object reads are range GETs against the Azure Blob REST API, the same
# shape as S3 and GCS, and a write is one Put Blob (a block blob, the bytes
# in the body), with these Azure divergences:
#
#   1. Auth is `Authorization: SharedKey <account>:<sig>` (handled by the
#      `komira_azure_blob.azure_signing.SharedKeySigningLayer` wrapping
#      the inner HttpService — AzureStore signs nothing itself). Anonymous
#      public-container reads pass through unsigned.
#   2. Addressing has two shapes, selected by AzureConfig:
#        * Virtual-hosted (real Azure): the account is the host's first
#          DNS label —  `<account>.blob.core.windows.net/<container>/<blob>`.
#        * Path-style (Azurite emulator): the account is the FIRST path
#          segment — `<host>:<port>/<account>/<container>/<blob>`.
#   3. List Blobs is `GET /<container>?restype=container&comp=list
#      [&prefix=X][&delimiter=Y][&marker=Z]` and returns an
#      <EnumerationResults> body (see azure_xml.mojo) — NOT the S3/GCS
#      <ListBucketResult> shape.
#   4. The x-ms-version header (e.g. "2021-08-06") is REQUIRED on every
#      authenticated request; the SharedKeySigningLayer signs it (it is an
#      x-ms-* header). AzureStore stamps a default x-ms-version on each
#      request. The x-ms-date header (RFC1123 GMT) — also REQUIRED for
#      Shared Key signing — is stamped by the SharedKeySigningLayer at sign
#      time (the wall clock, or a pinned date in a test), so the stamped
#      header and the signed header never drift.
#
# Per-method signatures take `mut connector: C` + `mut reactor: ...` so
# the HttpService.call seam is honored without AzureStore owning a
# connector.
#
# `abfs://` alias note: callers using the `abfs://` (Azure Data
# Lake Gen2 / ABFS) scheme are served through this FLAT Blob API — the
# container maps to the ABFS filesystem and the blob path maps to the
# ABFS file path. The hierarchical-namespace operations (rename, ACLs)
# are NOT exposed; flat range-GET reads are identical on the wire.
#
# No UnsafePointer in any signature, no wildcard origin, no
# unsafe_from_address, no take_pointee.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_http_client.body import BytesBody, EmptyBody
from komira_http_client.client import (
    build_get_request,
    build_head_request,
    build_request_with_body,
)
from komira_http_client.header_map import HeaderMap, sab_to_string
from komira_http_client.request_writer import method_put
from komira_http_client.response_body import BufferedResponseBody
from komira_http_client.service import ClientRequest, HttpService
from komira_http_client.state_machine import ClientResponse
from komira_http_client.url import Url
from komira_http_core.transport.io_stream import Connector

from .azure_xml import (
    AzureListBlobsResult,
    AzureParsedError,
    parse_azure_error,
    parse_azure_list_blobs_result,
)


# -----------------------------------------------------------------------------
# Canonical Azure Blob endpoint suffix + default API version
# -----------------------------------------------------------------------------

comptime AZURE_BLOB_DNS_SUFFIX: StaticString = "blob.core.windows.net"
comptime AZURE_DEFAULT_API_VERSION: StaticString = "2021-08-06"
comptime AZURE_BLOB_TYPE_BLOCK: StaticString = "BlockBlob"


# -----------------------------------------------------------------------------
# AzureBlobMeta — minimal HEAD result
# -----------------------------------------------------------------------------


@fieldwise_init
struct AzureBlobMeta(
    Movable, Copyable, ImplicitlyCopyable, Deinitable
):
    """Metadata for one Azure blob, from a HEAD response.

    Field layout:
      var size: Int64        — blob size in bytes; -1 if Content-Length
                               was omitted.
      var etag: String       — server-assigned ETag; empty if absent.
    """

    var size: Int64
    var etag: String

    @staticmethod
    def empty() -> AzureBlobMeta:
        return AzureBlobMeta(Int64(-1), String(""))


# -----------------------------------------------------------------------------
# AzureConfig — endpoint configuration POD
# -----------------------------------------------------------------------------


@fieldwise_init
struct AzureConfig(
    Copyable, ImplicitlyCopyable, Movable, Deinitable
):
    """Azure Blob endpoint configuration.

    Field layout:
      var account: String          — the storage account name (e.g.
                                     "mystoraccount").
      var endpoint_scheme: String   — "https" (real Azure) or "http"
                                     (Azurite emulator).
      var endpoint_host: String     — for real Azure,
                                     "<account>.blob.core.windows.net";
                                     for Azurite, the emulator host (e.g.
                                     "127.0.0.1").
      var endpoint_port: UInt16     — explicit port; 0 means scheme
                                     default (443/80).
      var path_style: Bool          — True for Azurite (account is the
                                     first path segment); False for real
                                     Azure (account is the DNS label).
      var api_version: String       — x-ms-version stamped on each request.

    Construct via `azure(account)` (real Azure) or `azurite(account)` /
    `custom(...)` (emulator).
    """

    var account: String
    var endpoint_scheme: String
    var endpoint_host: String
    var endpoint_port: UInt16
    var path_style: Bool
    var api_version: String

    @staticmethod
    def azure(account: String) -> AzureConfig:
        """Real-Azure config: https, virtual-hosted host
        `<account>.blob.core.windows.net`, account is the DNS label."""
        var host = account + String(".") + String(AZURE_BLOB_DNS_SUFFIX)
        return AzureConfig(
            account=account,
            endpoint_scheme=String("https"),
            endpoint_host=host^,
            endpoint_port=UInt16(0),
            path_style=False,
            api_version=String(AZURE_DEFAULT_API_VERSION),
        )

    @staticmethod
    def azurite(
        account: String,
        endpoint_host: String = String("127.0.0.1"),
        endpoint_port: UInt16 = UInt16(10000),
    ) -> AzureConfig:
        """Azurite emulator config: http, path-style (account is the
        first path segment). Azurite's default well-known account is
        `devstoreaccount1` on 127.0.0.1:10000."""
        return AzureConfig(
            account=account,
            endpoint_scheme=String("http"),
            endpoint_host=endpoint_host,
            endpoint_port=endpoint_port,
            path_style=True,
            api_version=String(AZURE_DEFAULT_API_VERSION),
        )

    @staticmethod
    def custom(
        account: String,
        endpoint_scheme: String,
        endpoint_host: String,
        endpoint_port: UInt16,
        path_style: Bool,
    ) -> AzureConfig:
        """Fully custom endpoint config (sovereign-cloud hosts, private
        endpoints, alternate emulators)."""
        return AzureConfig(
            account=account,
            endpoint_scheme=endpoint_scheme,
            endpoint_host=endpoint_host,
            endpoint_port=endpoint_port,
            path_style=path_style,
            api_version=String(AZURE_DEFAULT_API_VERSION),
        )


# -----------------------------------------------------------------------------
# URL builders — free functions (test-introspectable, no Store needed)
# -----------------------------------------------------------------------------


def _hex_upper(v: Int) -> String:
    if v < 10:
        return chr(0x30 + v)
    return chr(0x41 + (v - 10))


def _percent_encode_path_segment(s: String) -> String:
    """Percent-encode an object-key path component per RFC 3986. Blob
    names may contain `/` (preserved as path separators) and other
    reserved characters; we encode everything not unreserved or `/`."""
    var out = String()
    var bs = s.as_bytes()
    var n = len(bs)
    var i = 0
    while i < n:
        var c = bs[i]
        var is_unreserved = (
            (c >= UInt8(0x41) and c <= UInt8(0x5A))  # A-Z
            or (c >= UInt8(0x61) and c <= UInt8(0x7A))  # a-z
            or (c >= UInt8(0x30) and c <= UInt8(0x39))  # 0-9
            or c == UInt8(0x2D)  # -
            or c == UInt8(0x2E)  # .
            or c == UInt8(0x5F)  # _
            or c == UInt8(0x7E)  # ~
            or c == UInt8(0x2F)  # / (path separator — preserved)
        )
        if is_unreserved:
            out += chr(Int(c))
        else:
            out += "%"
            out += _hex_upper(Int(c) >> 4)
            out += _hex_upper(Int(c) & 0xF)
        i += 1
    return out^


def _percent_encode_query_value(s: String) -> String:
    """RFC 3986 percent-encode a query-parameter value."""
    var out = String()
    var bs = s.as_bytes()
    var n = len(bs)
    var i = 0
    while i < n:
        var c = bs[i]
        var is_unreserved = (
            (c >= UInt8(0x41) and c <= UInt8(0x5A))
            or (c >= UInt8(0x61) and c <= UInt8(0x7A))
            or (c >= UInt8(0x30) and c <= UInt8(0x39))
            or c == UInt8(0x2D)
            or c == UInt8(0x2E)
            or c == UInt8(0x5F)
            or c == UInt8(0x7E)
        )
        if is_unreserved:
            out += chr(Int(c))
        else:
            out += "%"
            out += _hex_upper(Int(c) >> 4)
            out += _hex_upper(Int(c) & 0xF)
        i += 1
    return out^


def _account_path_prefix(config: AzureConfig) -> String:
    """The leading path segment for the account: for path-style (Azurite)
    it is `/<account>`; for virtual-hosted (real Azure) it is empty (the
    account is the DNS label)."""
    if config.path_style:
        return String("/") + config.account
    return String("")


def build_azure_blob_url(
    config: AzureConfig, container: String, blob: String
) -> Url:
    """Build the blob object URL.

    Virtual-hosted (real Azure):  /<container>/<blob>
    Path-style (Azurite):         /<account>/<container>/<blob>
    """
    var path = _account_path_prefix(config)
    path += String("/")
    path += container
    path += String("/")
    path += _percent_encode_path_segment(blob)
    return Url(
        scheme=config.endpoint_scheme,
        host=config.endpoint_host,
        port=config.endpoint_port,
        path=path^,
    )


def build_azure_listing_url(
    config: AzureConfig,
    container: String,
    prefix: String,
    delimiter: String,
    marker: String,
) -> Url:
    """Build the List Blobs URL:
    `<endpoint>/<container>?restype=container&comp=list[&prefix=...]
    [&delimiter=...][&marker=...]` (path-style prefixes the account)."""
    var path = _account_path_prefix(config)
    path += String("/")
    path += container
    var url = Url(
        scheme=config.endpoint_scheme,
        host=config.endpoint_host,
        port=config.endpoint_port,
        path=path^,
    )
    # restype + comp are mandatory for List Blobs.
    var query = String("restype=container&comp=list")
    if prefix.byte_length() > 0:
        query += "&prefix="
        query += _percent_encode_query_value(prefix)
    if delimiter.byte_length() > 0:
        query += "&delimiter="
        query += _percent_encode_query_value(delimiter)
    if marker.byte_length() > 0:
        query += "&marker="
        query += _percent_encode_query_value(marker)
    url.query = query^
    return url^


# -----------------------------------------------------------------------------
# AzureStore[Http: HttpService] — the layered object store
# -----------------------------------------------------------------------------


struct AzureStore[Http: HttpService](Movable, Deinitable):
    """An Azure-Blob-backed object store. Parametric on a layered
    `Http: HttpService` — production stacks `SharedKeySigningLayer` over a
    real HttpClient; tests use a ScriptingHttpService (optionally wrapped
    by a SharedKeySigningLayer to exercise the auth header).

    Construction (production):
      var conn = KernelTcpConnector.new()
      var client = HttpClient[KernelTcpConnector].with_defaults(conn^)
      var provider = StaticSharedKeyProvider.make(account, key_b64)
      var layered = SharedKeySigningLayer.wrap(client^, provider^)
      var store = AzureStore.new(AzureConfig.azure(account), layered^)

    Field layout:
      var _config: AzureConfig
      var _http: Self.Http

    Mirrors S3Store / GcsStore exactly: per-method `mut connector: C` +
    `mut reactor` so the HttpService.call seam is honored without
    AzureStore owning a connector.
    """

    var _config: AzureConfig
    var _http: Self.Http

    @staticmethod
    def new(
        var config: AzureConfig,
        var http: Self.Http,
    ) -> AzureStore[Self.Http]:
        return AzureStore[Self.Http](_config=config^, _http=http^)

    def __init__(
        out self,
        var _config: AzureConfig,
        var _http: Self.Http,
    ):
        self._config = _config^
        self._http = _http^

    def config(self) -> AzureConfig:
        return self._config

    # ----- URL builders (test-introspectable) -----

    def build_blob_url(self, container: String, blob: String) -> Url:
        return build_azure_blob_url(self._config, container, blob)

    def build_listing_url(
        self,
        container: String,
        prefix: String,
        delimiter: String,
        marker: String,
    ) -> Url:
        return build_azure_listing_url(
            self._config, container, prefix, delimiter, marker
        )

    # ----- Internal: stamp the mandatory x-ms-version header -----

    def _base_headers(self) raises -> HeaderMap:
        var headers = HeaderMap()
        headers.append(String("x-ms-version"), self._config.api_version)
        return headers^

    # ----- Object operations (HEAD, GET, GET-Range) -----

    def head[RT: Runtime, C: Connector](
        mut self,
        container: String,
        blob: String,
        mut connector: C,
        mut reactor: Reactor[RT.Sink],
    ) raises -> AzureBlobMeta:
        """HEAD a blob — returns AzureBlobMeta extracted from response
        headers. On 4xx/5xx, raises Error(...) carrying the StoreError
        taxonomy in the message."""
        var url = self.build_blob_url(container, blob)
        var headers = self._base_headers()
        var req = build_head_request(url^, headers^)
        var resp = self._http.call[RT, C, EmptyBody](
            req^, connector, reactor,
        )
        var status_int = Int(resp.status)
        if status_int >= 400:
            raise self._mk_error(
                status_int, String("HEAD"), container, blob, String("")
            )
        var cl_int_opt = resp.headers.get_int64(String("content-length"))
        var content_length = (
            cl_int_opt.value() if cl_int_opt.__bool__() else Int64(-1)
        )
        var etag = String("")
        var etag_opt = resp.headers.get_view(String("etag"))
        if etag_opt.__bool__():
            etag = sab_to_string(etag_opt.value())
        return AzureBlobMeta(size=content_length, etag=etag^)

    def get_range[RT: Runtime, C: Connector](
        mut self,
        container: String,
        blob: String,
        start: Int64,
        end_inclusive: Int64,
        mut connector: C,
        mut reactor: Reactor[RT.Sink],
    ) raises -> List[UInt8]:
        """GET a byte-range from a blob. `[start, end_inclusive]` — the
        Range header is INCLUSIVE on both ends per RFC 7233 §3.1. Returns
        the response body bytes.

        `end_inclusive < 0` means "from start to EOF" (`bytes=start-`)."""
        var url = self.build_blob_url(container, blob)
        var headers = self._base_headers()
        if end_inclusive >= Int64(0) or start > Int64(0):
            var range_hdr = String("bytes=") + String(Int(start)) + String("-")
            if end_inclusive >= Int64(0):
                range_hdr = range_hdr + String(Int(end_inclusive))
            headers.append(String("Range"), range_hdr^)
        var req = build_get_request(url^, headers^)
        var resp = self._http.call[RT, C, EmptyBody](
            req^, connector, reactor,
        )
        var status_int = Int(resp.status)
        if status_int >= 400:
            var body_str = self._copy_response_body_as_string(resp)
            raise self._mk_error(
                status_int, String("GET"), container, blob, body_str^
            )
        return self._copy_response_body(resp)

    def get[RT: Runtime, C: Connector](
        mut self,
        container: String,
        blob: String,
        mut connector: C,
        mut reactor: Reactor[RT.Sink],
    ) raises -> List[UInt8]:
        """GET the full blob (no Range header)."""
        return self.get_range[RT, C](
            container, blob, Int64(0), Int64(-1), connector, reactor,
        )

    # ----- Put Blob (one request, block blob) -----

    def put_blob[RT: Runtime, C: Connector](
        mut self,
        container: String,
        blob: String,
        var data: List[UInt8],
        content_type: String,
        mut connector: C,
        mut reactor: Reactor[RT.Sink],
    ) raises -> AzureBlobMeta:
        """Put Blob: write `data` as the block blob `blob`, replacing any
        blob of that name (https://learn.microsoft.com/en-us/rest/api/storageservices/put-blob).

        `PUT /<container>/<blob>` with `x-ms-blob-type: BlockBlob`, the
        x-ms-version, `Content-Type: content_type` when it is non-empty,
        and the bytes as the body with their Content-Length. Returns the
        size written and the ETag of the 201 response. On a status of 300
        or more, raises Error(...) carrying the StoreError taxonomy. An
        empty `blob` is refused before any request: it would address the
        container."""
        if blob.byte_length() == 0:
            raise Error("azure store: refusing to put an empty blob name")
        var size = Int64(len(data))
        var url = self.build_blob_url(container, blob)
        var headers = self._base_headers()
        headers.append(String("x-ms-blob-type"), String(AZURE_BLOB_TYPE_BLOCK))
        if content_type.byte_length() > 0:
            headers.append(String("Content-Type"), content_type)
        var req = build_request_with_body[BytesBody](
            method_put(), url^, headers^, BytesBody.from_bytes(data^)
        )
        var resp = self._http.call[RT, C, BytesBody](
            req^, connector, reactor,
        )
        var status_int = Int(resp.status)
        if status_int >= 300:
            var body_str = self._copy_response_body_as_string(resp)
            raise self._mk_error(
                status_int, String("PUT"), container, blob, body_str^
            )
        var etag = String("")
        var etag_opt = resp.headers.get_view(String("etag"))
        if etag_opt.__bool__():
            etag = sab_to_string(etag_opt.value())
        return AzureBlobMeta(size=size, etag=etag^)

    # ----- Listing (single page) -----

    def list_page[RT: Runtime, C: Connector](
        mut self,
        container: String,
        prefix: String,
        delimiter: String,
        marker: String,
        mut connector: C,
        mut reactor: Reactor[RT.Sink],
    ) raises -> AzureListBlobsResult:
        """List ONE page of blobs matching `prefix`. The caller drives
        pagination via `result.is_truncated()` + `result.next_marker`
        (`?marker=<next_marker>` on the subsequent call)."""
        var url = self.build_listing_url(container, prefix, delimiter, marker)
        var headers = self._base_headers()
        var req = build_get_request(url^, headers^)
        var resp = self._http.call[RT, C, EmptyBody](
            req^, connector, reactor,
        )
        var status_int = Int(resp.status)
        if status_int >= 400:
            var body_str = self._copy_response_body_as_string(resp)
            raise self._mk_error(
                status_int, String("GET"), container, prefix, body_str^
            )
        var body = self._response_body_as_string(resp)
        return parse_azure_list_blobs_result(body)

    # ----- Internal helpers (mirror S3Store / GcsStore) -----

    def _copy_response_body_as_string(
        self, ref resp: ClientResponse[BufferedResponseBody]
    ) -> String:
        """An error response's body as UTF-8 text, a leading byte order
        mark kept for komira_xml to step over; "" when the body is not
        UTF-8 (the error then carries no azure_code)."""
        try:
            return self._response_body_as_string(resp)
        except:
            return String("")

    def _copy_response_body(
        self, ref resp: ClientResponse[BufferedResponseBody]
    ) -> List[UInt8]:
        ref src = resp.body.bytes_ref()
        var out = List[UInt8]()
        var i = 0
        var n = src.__len__()
        while i < n:
            out.append(src[i])
            i += 1
        return out^

    def _response_body_as_string(
        self, ref resp: ClientResponse[BufferedResponseBody]
    ) raises -> String:
        """The body's bytes as a String, validated as UTF-8. Azure starts
        its XML bodies with a UTF-8 byte order mark; the bytes are kept as
        they are, so komira_xml sees and steps over it, and a multi-byte
        blob name reads as its code points. Raises when the bytes are not
        UTF-8."""
        ref src = resp.body.bytes_ref()
        try:
            return String(StringSlice(from_utf8=Span(src)))
        except:
            raise Error("azure store: response body is not UTF-8")

    def _mk_error(
        self,
        status: Int,
        method: String,
        container: String,
        blob: String,
        var body: String,
    ) -> Error:
        """Build an Error carrying a StoreError-shaped message. Tests
        recover the taxonomy via `azure_store_error_kind_from_message`."""
        var az_err = AzureParsedError.empty()
        if body.byte_length() > 0:
            try:
                az_err = parse_azure_error(body)
            except:
                pass
        var msg = String("StoreError[")
        if status == 404:
            msg += "NOT_FOUND"
        elif status == 401 or status == 403:
            msg += "PERMISSION_DENIED"
        elif status == 429 or status == 503:
            msg += "THROTTLED"
        elif status == 412 or status == 304:
            msg += "PRECONDITION"
        elif status >= 500:
            msg += "TRANSPORT"
        else:
            msg += "MALFORMED"
        msg += "] "
        msg += method
        msg += " az://"
        msg += container
        msg += "/"
        msg += blob
        msg += " status="
        msg += String(status)
        if az_err.code.byte_length() > 0:
            msg += " azure_code="
            msg += String(az_err.code)
        if az_err.message.byte_length() > 0:
            msg += " azure_message="
            msg += String(az_err.message)
        return Error(msg^)


# -----------------------------------------------------------------------------
# Error-message inspection (for tests + retry classifier consumers)
# -----------------------------------------------------------------------------

comptime AZURE_ERR_NONE: UInt8 = 0
comptime AZURE_ERR_NOT_FOUND: UInt8 = 1
comptime AZURE_ERR_PERMISSION_DENIED: UInt8 = 2
comptime AZURE_ERR_THROTTLED: UInt8 = 3
comptime AZURE_ERR_PRECONDITION: UInt8 = 4
comptime AZURE_ERR_TRANSPORT: UInt8 = 5
comptime AZURE_ERR_MALFORMED: UInt8 = 6


def azure_store_error_kind_from_message(msg: String) -> UInt8:
    """Recover the StoreError kind from the message prefix
    "StoreError[<KIND>]". Returns AZURE_ERR_NONE if no match."""
    if msg.find(String("StoreError[NOT_FOUND]")) >= 0:
        return AZURE_ERR_NOT_FOUND
    if msg.find(String("StoreError[PERMISSION_DENIED]")) >= 0:
        return AZURE_ERR_PERMISSION_DENIED
    if msg.find(String("StoreError[THROTTLED]")) >= 0:
        return AZURE_ERR_THROTTLED
    if msg.find(String("StoreError[PRECONDITION]")) >= 0:
        return AZURE_ERR_PRECONDITION
    if msg.find(String("StoreError[TRANSPORT]")) >= 0:
        return AZURE_ERR_TRANSPORT
    if msg.find(String("StoreError[MALFORMED]")) >= 0:
        return AZURE_ERR_MALFORMED
    return AZURE_ERR_NONE
