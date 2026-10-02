# =============================================================================
# komira_aws_core/credential_transport.mojo -- the credential providers' seam
# =============================================================================
#
# The network-backed credential providers (STS, the container endpoint, the
# instance metadata service) are REQUEST BUILDERS and RESPONSE PARSERS. The
# exchange between them goes through `CredentialTransport`, which a caller
# implements: the HTTP client in production, a scripted double in tests. This
# package opens no socket.
#
# A request can carry a secret (a web identity token, a container
# authorization token, a metadata session token, a SigV4 signature over a
# session token). `CredentialHttpRequest` is not `Writable`; `to_wire()` is the
# exact HTTP/1.1 bytes the transport should send and exists for the transport
# and for the byte-exact tests. Never log it.
# =============================================================================

from ._text import bytes_of, utf8_text
from .sigv4 import Header


struct CredentialHttpRequest(Copyable, Movable):
    """One HTTP request a credential provider wants sent.

    `scheme` is "http" or "https"; `host` is the host name or IP literal (an
    IPv6 literal in brackets); `port` is the TCP port; `target` is the path
    and query. `headers` are in send order and include Host. `body` is
    bytes; `set_body_text` and `body_text` write and read it as UTF-8.
    """

    var method: String
    var scheme: String
    var host: String
    var port: Int
    var target: String
    var headers: List[Header]
    var body: List[UInt8]

    def __init__(
        out self,
        method: String,
        scheme: String,
        host: String,
        port: Int,
        target: String,
    ):
        self.method = method
        self.scheme = scheme
        self.host = host
        self.port = port
        self.target = target
        self.headers = List[Header]()
        self.body = List[UInt8]()

    def header(self, name: String) -> String:
        """The first header named `name` (exact case), "" when absent."""
        for i in range(len(self.headers)):
            if self.headers[i].name == name:
                return self.headers[i].value
        return String("")

    def set_body_text(mut self, text: String):
        """Sets the body to the UTF-8 bytes of `text`."""
        self.body = bytes_of(text)

    def body_text(self) raises -> String:
        """The body as text. Refuses a body that is not well-formed UTF-8."""
        return utf8_text(Span(self.body), "the request body")

    def to_wire(self) -> List[UInt8]:
        """The HTTP/1.1 request bytes: request line, headers, blank line,
        body. Holds secrets; for the transport and tests only."""
        var head = self.method + " " + self.target + " HTTP/1.1\r\n"
        for i in range(len(self.headers)):
            head += self.headers[i].name + ": " + self.headers[i].value + "\r\n"
        head += "\r\n"
        var out = bytes_of(head)
        out.extend(Span(self.body))
        return out^


@fieldwise_init
struct CredentialHttpResponse(Copyable, Movable):
    """The status code and body of a response. Bodies hold secrets."""

    var status: Int
    var body: String


trait CredentialTransport:
    """Sends one request and returns the response.

    Raises when no response arrives (no route, refused, timed out). The
    chain treats a raise from the instance metadata service as "not on EC2"
    and any other raise as a failure of a configured provider.
    """

    def send(
        mut self, req: CredentialHttpRequest
    ) raises -> CredentialHttpResponse:
        ...


def host_header(host: String, port: Int, scheme: String) -> String:
    """The Host header value: the port is omitted when it is the scheme's
    default."""
    if (scheme == "http" and port == 80) or (scheme == "https" and port == 443):
        return host
    return host + ":" + String(port)
