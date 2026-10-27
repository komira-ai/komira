# =============================================================================
# auth_header -- the seam that supplies the authorization header of one
# outbound request, and two conformers.
# =============================================================================
#
# A model endpoint usually wants a credential in a request header. The library
# fixes neither the header's name nor its scheme nor where the credential comes
# from: the host passes an `AuthHeaderProvider`, and the transport asks it once
# per request, so a provider that rotates its credential is read afresh each
# time. The library reads no environment variable.
#
# A header is a name and a value. Both are checked before they reach the wire:
# a name must be an HTTP token, a value must hold no control byte (a line break
# in a value would end the header and start another), and a name the transport
# owns (the body's length and type, the host, the connection handling) is
# refused so a provider cannot desynchronise the request.
#
# `NoAuth` sends no header. `StaticAuthHeader` sends one fixed header.
# =============================================================================

# The longest header value the transport sends.
comptime AUTH_HEADER_MAX_VALUE_BYTES: Int = 8192
# The longest header name the transport sends.
comptime AUTH_HEADER_MAX_NAME_BYTES: Int = 128


@fieldwise_init
struct AuthHeader(Copyable, Movable):
    """One request header: its name and its value.

    Fields:
        name: The header name, an HTTP token (for example the name a gateway
            documents for its credential).
        value: The complete header value, formatted by the provider.
    """

    var name: String
    var value: String


trait AuthHeaderProvider(Movable, Deinitable):
    """The authorization header for one outbound request.

    All methods take an immutable `self`. The transport calls `header` once for
    every request it sends.
    """

    def header(self) raises -> Optional[AuthHeader]:
        """The header to add to the request.

        Returns:
            The header, or `None` to send the request without one. A provider
            that cannot produce a credential raises, and the request is not
            sent.
        """
        ...


struct NoAuth(AuthHeaderProvider):
    """A provider that adds no header."""

    def __init__(out self):
        pass

    def header(self) raises -> Optional[AuthHeader]:
        """Always `None`.

        Returns:
            No header.
        """
        return Optional[AuthHeader]()


struct StaticAuthHeader(AuthHeaderProvider):
    """A provider that adds one fixed header, checked when it is built."""

    var _header: AuthHeader

    def __init__(out self, name: String, value: String) raises:
        """A provider of the header `name: value`.

        Args:
            name: The header name.
            value: The complete header value.

        Raises:
            When the name or the value would not be a safe header (see
            `validate_auth_header`).
        """
        var h = AuthHeader(name, value)
        validate_auth_header(h)
        self._header = h^

    def header(self) raises -> Optional[AuthHeader]:
        """The fixed header.

        Returns:
            A copy of the header given at construction.
        """
        return Optional[AuthHeader](self._header.copy())


def validate_auth_header(header: AuthHeader) raises:
    """Refuse a header that could not be sent safely.

    The name must be a non-empty HTTP token of at most
    `AUTH_HEADER_MAX_NAME_BYTES` bytes and not one of the headers the transport
    writes itself (`host`, `content-length`, `content-type`, `accept`,
    `transfer-encoding`, `connection`, `upgrade`, `expect`, in any case). The
    value must be non-empty, at most `AUTH_HEADER_MAX_VALUE_BYTES` bytes, and
    hold no control byte other than a horizontal tab and no DEL.

    Args:
        header: The header to check.

    Raises:
        An error naming the rule, never the value (a value is a credential).
    """
    var name = header.name.as_bytes()
    if len(name) == 0:
        raise Error("auth header: the name is empty")
    if len(name) > AUTH_HEADER_MAX_NAME_BYTES:
        raise Error(
            "auth header: the name is longer than "
            + String(AUTH_HEADER_MAX_NAME_BYTES)
            + " bytes"
        )
    for i in range(len(name)):
        if not _is_token_byte(name[i]):
            raise Error("auth header: the name is not an HTTP token")
    if _is_transport_header(header.name):
        raise Error(
            "auth header: the name is a header the transport writes itself"
        )
    var value = header.value.as_bytes()
    if len(value) == 0:
        raise Error("auth header: the value is empty")
    if len(value) > AUTH_HEADER_MAX_VALUE_BYTES:
        raise Error(
            "auth header: the value is longer than "
            + String(AUTH_HEADER_MAX_VALUE_BYTES)
            + " bytes"
        )
    for i in range(len(value)):
        var b = value[i]
        if (b < 0x20 and b != 0x09) or b == 0x7F:
            raise Error("auth header: the value holds a control byte")


def _is_token_byte(b: UInt8) -> Bool:
    """Whether `b` may appear in an HTTP token (the HTTP token grammar)."""
    if b >= 0x30 and b <= 0x39:
        return True
    if b >= 0x41 and b <= 0x5A:
        return True
    if b >= 0x61 and b <= 0x7A:
        return True
    # ! # $ % & ' * + - . ^ _ ` | ~
    return (
        b == 0x21
        or b == 0x23
        or b == 0x24
        or b == 0x25
        or b == 0x26
        or b == 0x27
        or b == 0x2A
        or b == 0x2B
        or b == 0x2D
        or b == 0x2E
        or b == 0x5E
        or b == 0x5F
        or b == 0x60
        or b == 0x7C
        or b == 0x7E
    )


def _is_transport_header(name: String) -> Bool:
    """Whether `name` is a header the transport writes itself (any case)."""
    var bytes = name.as_bytes()
    var raw = List[UInt8](capacity=len(bytes))
    for i in range(len(bytes)):
        var b = bytes[i]
        if b >= 0x41 and b <= 0x5A:
            b += 32
        raw.append(b)
    var lower = String(from_utf8_lossy=Span(raw))
    return (
        lower == "host"
        or lower == "content-length"
        or lower == "content-type"
        or lower == "accept"
        or lower == "transfer-encoding"
        or lower == "connection"
        or lower == "upgrade"
        or lower == "expect"
    )
