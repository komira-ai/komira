# =============================================================================
# komira_gcp_wif/_post.mojo — one HTTPS POST over komira_http_client.
# =============================================================================
#
# Private to the package (not re-exported). Both legs send exactly one POST
# with a body, and read the status and the whole body back; this is that, over
# the `HttpClient[C]` and the `BlockingRuntime` the caller owns. The header
# set is the point: `Content-Type`, plus `Authorization` only when the caller
# names one. The client adds `Host` (from the URL), `Content-Length` and
# `User-Agent`; nothing else is sent.
#
# `get` is the one GET: an external-account file's `credential_source.url`,
# with exactly the headers the file names (external_account.mojo checked
# them), over http or https as the URL says.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_http_client.body import BytesBody, EmptyBody
from komira_http_client.client import HttpClient, build_request_with_body
from komira_http_client.header_map import HeaderMap
from komira_http_client.url import Url
from komira_http_core.codec.types import HttpMethod
from komira_http_core.transport.io_stream import Connector


struct PostReply(Movable, Deinitable):
    """A response: its status and its whole body."""

    var status: Int
    var body: List[UInt8]

    def __init__(out self, status: Int, var body: List[UInt8]):
        self.status = status
        self.body = body^

    def is_success(self) -> Bool:
        return self.status >= 200 and self.status < 300


def check_host(what: String, host: String) raises:
    """A host override: a non-empty run of `[a-z0-9.-]`. It is spliced into
    the URL a credential is sent to, so a `/`, `@`, `:` or `#` in it would
    send that credential somewhere other than the host it names."""
    var b = host.as_bytes()
    if len(b) == 0:
        raise Error("komira_gcp_wif: the " + what + " host is empty")
    for i in range(len(b)):
        var c = b[i]
        var ok = (
            (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
            or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
            or c == UInt8(ord("."))
            or c == UInt8(ord("-"))
        )
        if not ok:
            raise Error(
                "komira_gcp_wif: the " + what + " host holds a byte outside"
                " [a-z0-9.-]"
            )


def new_runtime() raises -> BlockingRuntime[NoopSink]:
    """The current-thread runtime each sender drives its client on."""
    return BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))


def post[
    C: Connector
](
    mut client: HttpClient[C],
    mut rt: BlockingRuntime[NoopSink],
    host: String,
    path: String,
    content_type: String,
    authorization: String,
    body: String,
) raises -> PostReply:
    """POST `body` to `https://<host><path>`. `authorization` is sent only
    when it is not empty."""
    var headers = HeaderMap()
    headers.append(String("Content-Type"), content_type.copy())
    if authorization.byte_length() > 0:
        headers.append(String("Authorization"), authorization.copy())
    var req = build_request_with_body[BytesBody](
        HttpMethod.post(),
        Url.https(host.copy(), UInt16(443), path.copy()),
        headers^,
        BytesBody.from_str(body),
    )
    ref reactor = rt.reactor()
    var resp = client.send_buffered[BlockingRuntime[NoopSink], BytesBody](
        req^, reactor
    )
    return PostReply(Int(resp.status), resp.body.take_bytes())


def get[
    C: Connector
](
    mut client: HttpClient[C],
    mut rt: BlockingRuntime[NoopSink],
    var url: Url,
    header_names: List[String],
    header_values: List[String],
) raises -> PostReply:
    """GET `url` with exactly the headers given (name `i` with value `i`)."""
    var headers = HeaderMap()
    for i in range(len(header_names)):
        headers.append(header_names[i].copy(), header_values[i].copy())
    var req = build_request_with_body[EmptyBody](
        HttpMethod.get(), url^, headers^, EmptyBody.new()
    )
    ref reactor = rt.reactor()
    var resp = client.send_buffered[BlockingRuntime[NoopSink], EmptyBody](
        req^, reactor
    )
    return PostReply(Int(resp.status), resp.body.take_bytes())
