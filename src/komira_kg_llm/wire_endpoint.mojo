# =============================================================================
# wire_endpoint -- where a transport posts, and the bounds on the exchange.
# =============================================================================
#
# An endpoint is a host, a port and a request path, plus the two bounds every
# exchange is held to: how long to wait, and how large a response to accept.
# All five are the caller's: there is no default address, path, timeout or size.
# The scheme is not part of the endpoint; it follows the connector the transport
# is built over (a plaintext connector posts `http`, a TLS connector `https`).
#
# The time bound is a number of milliseconds handed to the HTTP client, which
# enforces it with its own clock; nothing here reads a clock. The same number is
# passed to the connector factory, so a connector can apply it to its own
# phases (a TLS handshake, for one).
#
# The host and the path end up on the request line and in the Host header, so
# both are checked for the bytes that would let a caller-supplied string end the
# line and start another.
# =============================================================================

# The longest host name a DNS name can be.
comptime ENDPOINT_MAX_HOST_BYTES: Int = 253
# The longest request path the endpoint accepts.
comptime ENDPOINT_MAX_PATH_BYTES: Int = 2048


struct WireEndpoint(Copyable, Movable):
    """The address of a model service and the bounds on one exchange with it.

    Fields:
        host: The host name or IPv4 address, letters, digits, `.`, `-` and `_`.
        port: The TCP port, not zero.
        path: The request path, beginning with `/`, printable ASCII without a
            space and without `#`.
        timeout_ms: The most a request may take from the start of the send to
            the parsed response head, in milliseconds. More than zero.
        max_response_bytes: The largest response body accepted, in bytes. More
            than zero.
    """

    var host: String
    var port: UInt16
    var path: String
    var timeout_ms: Int
    var max_response_bytes: Int

    def __init__(
        out self,
        host: String,
        port: UInt16,
        path: String,
        *,
        timeout_ms: Int,
        max_response_bytes: Int,
    ) raises:
        """Check and keep an endpoint.

        Args:
            host: The host name or address.
            port: The port.
            path: The request path.
            timeout_ms: The request time bound, milliseconds.
            max_response_bytes: The response size bound, bytes.

        Raises:
            When any field breaks the rule given on the struct.
        """
        var h = host.as_bytes()
        if len(h) == 0:
            raise Error("endpoint: the host is empty")
        if len(h) > ENDPOINT_MAX_HOST_BYTES:
            raise Error("endpoint: the host is longer than 253 bytes")
        for i in range(len(h)):
            if not _is_host_byte(h[i]):
                raise Error("endpoint: the host holds a byte a host name cannot")
        if port == 0:
            raise Error("endpoint: the port is zero")
        var p = path.as_bytes()
        if len(p) == 0 or p[0] != 0x2F:
            raise Error("endpoint: the path must begin with '/'")
        if len(p) > ENDPOINT_MAX_PATH_BYTES:
            raise Error("endpoint: the path is longer than 2048 bytes")
        for i in range(len(p)):
            if p[i] <= 0x20 or p[i] >= 0x7F or p[i] == 0x23:
                raise Error(
                    "endpoint: the path holds a space, a control or non-ASCII"
                    " byte, or '#'"
                )
        if timeout_ms <= 0:
            raise Error("endpoint: timeout_ms must be more than zero")
        # The client takes microseconds.
        if timeout_ms > Int.MAX // 1000:
            raise Error("endpoint: timeout_ms is too large")
        if max_response_bytes <= 0:
            raise Error("endpoint: max_response_bytes must be more than zero")
        self.host = host
        self.port = port
        self.path = path
        self.timeout_ms = timeout_ms
        self.max_response_bytes = max_response_bytes

    def timeout_us(self) -> Int:
        """The time bound in microseconds, as the HTTP client takes it.

        Returns:
            `timeout_ms * 1000`.
        """
        return self.timeout_ms * 1000


def _is_host_byte(b: UInt8) -> Bool:
    """Whether `b` may appear in a host name or an IPv4 address."""
    return (
        (b >= 0x30 and b <= 0x39)
        or (b >= 0x41 and b <= 0x5A)
        or (b >= 0x61 and b <= 0x7A)
        or b == 0x2E
        or b == 0x2D
        or b == 0x5F
    )
