# =============================================================================
# komira_azure_blob/azure_sas_query.mojo — a SAS token on every request
# =============================================================================
#
# A SAS token (a shared access signature: `sv=...&sp=r&sig=...`, minted by
# the account owner or by `AzureSasSigner`) authorizes a request by riding in
# its query string: Azure checks the `sig` parameter and needs no
# Authorization header. `SasQueryLayer[Inner]` is the HttpService layer that
# appends the token to each request's query, after any query the request
# already has (List Blobs' `restype=container&comp=list...`), and passes it
# on. An empty token passes every request through unchanged.
#
# The layer rewrites only the request line's request-target in the
# serialized bytes: the headers and any body bytes after the request line
# are kept byte for byte, so a layer that signs or frames a body below or
# above it is unaffected.
#
# `azure_sas_query_normalize` is the token check every entry point uses: a
# leading `?` (as the Azure portal prints a token) is dropped, and a token
# that is empty, has no `sig=` parameter, or holds a byte that is not
# visible ASCII or is `#` is refused. The refusals never echo the token: it
# is a secret.
#
# No UnsafePointer in any signature, no wildcard origin.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_http_client.body import RequestBody
from komira_http_client.response_body import BufferedResponseBody
from komira_http_client.service import ClientRequest, HttpLayer, HttpService
from komira_http_client.state_machine import ClientResponse
from komira_http_core.transport.io_stream import Connector


def azure_sas_query_normalize(token: String) raises -> String:
    """`token` without a leading `?`, after checking it is a SAS query
    string. Raises `azure_sas: ...` for an empty token, one with no `sig=`
    parameter, or one holding a byte outside visible ASCII (0x21 to 0x7E)
    or a `#`; the message names the byte offset, never the token."""
    var bs = token.as_bytes()
    var start = 0
    if len(bs) > 0 and bs[0] == UInt8(ord("?")):
        start = 1
    if len(bs) - start == 0:
        raise Error("azure_sas: the SAS token is empty")
    for i in range(start, len(bs)):
        var c = bs[i]
        if c < UInt8(0x21) or c > UInt8(0x7E) or c == UInt8(ord("#")):
            raise Error(
                "azure_sas: the SAS token holds a byte that is not visible"
                " ASCII or is '#', at offset "
                + String(i)
            )
    var out = String(token[byte=start:token.byte_length()])
    if not (out.startswith("sig=") or out.find("&sig=") >= 0):
        raise Error("azure_sas: the SAS token carries no sig= parameter")
    return out^


def _with_request_target(bytes: List[UInt8], target: String) raises -> List[UInt8]:
    """`bytes` (a serialized request) with its request line's
    request-target replaced by `target`; every byte after the target's end
    is kept."""
    var n = len(bytes)
    var line_end = -1
    for i in range(n - 1):
        if bytes[i] == UInt8(13) and bytes[i + 1] == UInt8(10):
            line_end = i
            break
    var first_sp = -1
    var last_sp = -1
    for i in range(max(line_end, 0)):
        if bytes[i] == UInt8(32):
            if first_sp < 0:
                first_sp = i
            last_sp = i
    if line_end < 0 or first_sp < 0 or last_sp <= first_sp:
        raise Error("SasQueryLayer: the request bytes carry no request line")
    var out = List[UInt8](capacity=n + target.byte_length())
    for i in range(first_sp + 1):
        out.append(bytes[i])
    out.extend(Span(target.as_bytes()))
    for i in range(last_sp, n):
        out.append(bytes[i])
    return out^


struct SasQueryLayer[Inner: HttpService](HttpService, HttpLayer, Movable, Deinitable):
    """Appends a SAS token to every request's query (module header); an
    empty token passes requests through unchanged.

    Construction: `SasQueryLayer.wrap(inner, token)`, which checks the token
    (`azure_sas_query_normalize`) unless it is empty."""

    var _inner: Self.Inner
    var _sas_query: String

    def __init__(out self, var _inner: Self.Inner, var _sas_query: String):
        self._inner = _inner^
        self._sas_query = _sas_query^

    @staticmethod
    def wrap(var inner: Self.Inner, token: String) raises -> Self:
        """The layer over `inner` appending `token` ("" for none)."""
        var q = String("")
        if token.byte_length() > 0:
            q = azure_sas_query_normalize(token)
        return Self(_inner=inner^, _sas_query=q^)

    def layer_name(self) -> String:
        return String("azure-sas-query")

    @always_inline
    def has_token(self) -> Bool:
        """True when requests carry a SAS token."""
        return self._sas_query.byte_length() > 0

    def call[RT: Runtime, C: Connector, B: RequestBody](
        mut self,
        var req: ClientRequest[B],
        mut connector: C,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[BufferedResponseBody]:
        """HttpService.call: append the token to `req`'s query and its
        request line, then delegate to the inner service."""
        if self._sas_query.byte_length() == 0:
            return self._inner.call[RT, C, B](req^, connector, reactor)
        if req.url.query.byte_length() > 0:
            req.url.query += "&"
        req.url.query += self._sas_query
        req.request_bytes = _with_request_target(
            req.request_bytes, req.url.request_target()
        )
        return self._inner.call[RT, C, B](req^, connector, reactor)
