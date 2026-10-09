# =============================================================================
# komira_github/header.mojo -- one HTTP header as a name and a value, and the
#   case-insensitive lookups the client, the webhook check and the fake use.
# =============================================================================


@fieldwise_init
struct GitHubHeader(Copyable, Movable, Deinitable, ImplicitlyCopyable):
    """One header line, as received (the name keeps its case)."""

    var name: String
    var value: String


def ascii_lower(s: String) -> String:
    """`s` with A-Z mapped to a-z; every other byte as it is."""
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        var c = b[i]
        if c >= UInt8(0x41) and c <= UInt8(0x5A):
            c += 0x20
        out.append(c)
    return String(unsafe_from_utf8=Span(out))


def header_count(headers: List[GitHubHeader], name: String) -> Int:
    """How many headers are named `name`, ignoring ASCII case."""
    var want = ascii_lower(name)
    var n = 0
    for i in range(len(headers)):
        if ascii_lower(headers[i].name) == want:
            n += 1
    return n


def header_value(headers: List[GitHubHeader], name: String) -> Optional[String]:
    """The value of the first header named `name` (ASCII case ignored)."""
    var want = ascii_lower(name)
    for i in range(len(headers)):
        if ascii_lower(headers[i].name) == want:
            return headers[i].value
    return None
