# =============================================================================
# src/komira_http/client/url.mojo — Parsed Url type
# =============================================================================
#
# URLs are parsed ONCE, at request build. Re-parsing a raw String in
# PoolKey, in the request-line writer and in the signer's view is a
# correctness divergence risk (percent-encoding, IPv6-literal hosts
# [::1], default ports, userinfo).
#
# Shape:
#   * `scheme`     — "http" | "https" (lowercased on parse).
#   * `userinfo`   — userinfo segment of authority (rare; common in S3
#                    pre-signed URLs is `https://user:pass@host/...` but
#                    productionconfig usually omits it). Default empty.
#   * `host`       — registered name or IP-literal. For IPv6 the host
#                    field stores the address WITHOUT brackets; the
#                    bracket convention belongs to the wire form, not
#                    the parsed field.
#   * `port`       — explicit port; 0 if absent (caller uses default
#                    based on scheme).
#   * `path`       — path component INCLUDING leading "/". An empty path
#                    becomes "/" (the canonical default).
#   * `query`      — query string WITHOUT leading "?". Empty if absent.
#   * `fragment`   — fragment WITHOUT leading "#". Empty if absent.
#                    Note: RFC 7230 §5.1 says fragments are stripped before
#                    request emission — we parse them for completeness
#                    but request_writer.mojo never emits them.
#
# Parse is strict-tolerant:
#   * Rejects malformed schemes, missing host, port out of range.
#   * Accepts IPv6 in `[...]`, decodes the literal.
#   * Does NOT percent-decode (per RFC 3986 the path is preserved
#     percent-encoded on the wire; the application layer decodes as
#     needed). path/query bytes pass through verbatim.
#
# Pointer discipline:
#   * ZERO UnsafePointer in any signature.
#   * ZERO wildcard origins.
#   * `Url` is an owned-strings POD; no borrowed-origin fields.
# =============================================================================

from .error import HttpError


# =============================================================================
# §1 — Helpers.
# =============================================================================


@always_inline
def _is_digit(b: UInt8) -> Bool:
    var c = Int(b)
    return c >= Int(ord("0")) and c <= Int(ord("9"))


@always_inline
def _is_alpha(b: UInt8) -> Bool:
    var c = Int(b)
    if c >= Int(ord("a")) and c <= Int(ord("z")):
        return True
    if c >= Int(ord("A")) and c <= Int(ord("Z")):
        return True
    return False


@always_inline
def _to_lower_ascii(b: UInt8) -> UInt8:
    var c = Int(b)
    if c >= Int(ord("A")) and c <= Int(ord("Z")):
        return UInt8(c + 32)
    return b


def _slice(s: String, start: Int, end_excl: Int) -> String:
    """Substring helper. ASCII-byte-indexed slice. Caller ensures
    [start, end_excl) is within bounds + ASCII-safe."""
    var bytes_ref = s.as_bytes()
    var n = len(bytes_ref)
    if start < 0:
        return String()
    if end_excl > n:
        return String()
    var out = String()
    var i = start
    while i < end_excl:
        out = out + chr(Int(bytes_ref[i]))
        i = i + 1
    return out^


# =============================================================================
# §2 — Url struct.
# =============================================================================


struct Url(Movable, Deinitable):
    """Parsed URL. Movable, NOT Copyable — owned strings.

    Construct via:
      * `Url.parse(s) raises -> Url` — strict parse from a string. Raises
        on malformed input. Use this at the request boundary.
      * `Url.http(host, port, path)` / `Url.https(host, port, path)` —
        convenience constructors for tests / well-known endpoints.

    Field invariants (post-construction):
      * scheme is lowercase, non-empty, "http" or "https"
      * host is non-empty (post-parse)
      * port is in [0, 65535]; 0 means "use scheme default"
      * path is non-empty; starts with "/" (canonicalized)
    """

    var scheme: String
    var userinfo: String
    var host: String
    var port: UInt16
    var path: String
    var query: String
    var fragment: String

    def __init__(out self):
        self.scheme = String()
        self.userinfo = String()
        self.host = String()
        self.port = UInt16(0)
        self.path = String("/")
        self.query = String()
        self.fragment = String()

    def __init__(
        out self,
        var scheme: String,
        var host: String,
        port: UInt16,
        var path: String,
    ):
        self.scheme = scheme^
        self.userinfo = String()
        self.host = host^
        self.port = port
        self.path = path^
        self.query = String()
        self.fragment = String()

    @staticmethod
    def http(var host: String, port: UInt16, var path: String) -> Url:
        """Construct an http:// URL for tests / well-known endpoints."""
        return Url(scheme=String("http"), host=host^, port=port, path=path^)

    @staticmethod
    def https(var host: String, port: UInt16, var path: String) -> Url:
        """Construct an https:// URL for tests / well-known endpoints."""
        return Url(scheme=String("https"), host=host^, port=port, path=path^)

    def default_port(self) -> UInt16:
        """The scheme's default port — 80 for http, 443 for https, 0 if
        the scheme isn't recognized."""
        if self.scheme == String("http"):
            return UInt16(80)
        if self.scheme == String("https"):
            return UInt16(443)
        return UInt16(0)

    def is_https(ref self) -> Bool:
        """True iff scheme is exactly "https". Used by HttpClient.send
        to verify connector/scheme compatibility WITHOUT consuming
        scheme via `==` from the caller's frame (Mojo 1.0.0b1
        partial-move discipline). `ref self` bound to preserve the
        caller's `req.url` borrow."""
        return self.scheme == String("https")

    def is_http(ref self) -> Bool:
        """True iff scheme is exactly "http". Companion to is_https."""
        return self.scheme == String("http")

    def host_copy(ref self) -> String:
        """Return an owned copy of the host string. Used by callers
        that need an owned String for downstream consumption (e.g.
        IP-literal parsing) without consuming `self.host`."""
        return String(self.host)

    def effective_port(ref self) -> UInt16:
        """The port to actually use — explicit `port` if set, otherwise
        the scheme default. `ref self` bound."""
        if self.port != UInt16(0):
            return self.port
        # Inline default_port logic (call to self.default_port() would
        # consume self by value).
        if self.scheme == String("http"):
            return UInt16(80)
        if self.scheme == String("https"):
            return UInt16(443)
        return UInt16(0)

    def authority(self) -> String:
        """Reconstruct the authority segment for emission. Host:port if
        port is explicit AND non-default; otherwise host alone. IPv6
        host gets bracketed."""
        var host_emit = self.host
        if self._host_is_ipv6():
            host_emit = String("[") + self.host + String("]")
        var port_explicit = self.port != UInt16(0)
        var port_is_default = self.port == self.default_port()
        if port_explicit and not port_is_default:
            return host_emit + String(":") + String(Int(self.port))
        return host_emit^

    def request_target(self) -> String:
        """The "request-target" form per RFC 7230 §5.3.1 origin-form:
        path + "?" + query if query is non-empty. Used by the request
        writer for the request line."""
        if len(self.query.as_bytes()) > 0:
            return self.path + String("?") + self.query
        return self.path

    @always_inline
    def _host_is_ipv6(self) -> Bool:
        """Heuristic: an IPv6 host has at least 2 colons. Since DNS
        names never contain colons, this is a sufficient predicate for
        bracketing on emission."""
        var bytes_ref = self.host.as_bytes()
        var n = len(bytes_ref)
        var colons = 0
        var i = 0
        while i < n:
            if bytes_ref[i] == UInt8(ord(":")):
                colons = colons + 1
                if colons >= 2:
                    return True
            i = i + 1
        return False

    @staticmethod
    def parse(s: String) raises -> Url:
        """Parse a URL string. Raises HttpError-shaped Error on malformed
        input.

        Grammar (subset of RFC 3986 sufficient for http/https):
          url     = scheme ":" "//" authority path [ "?" query ] [ "#" fragment ]
          scheme  = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )
          authority = [ userinfo "@" ] host [ ":" port ]
          host    = IP-literal / IPv4address / reg-name
          path    = *pchar      (starts with "/")
        """
        var bytes_ref = s.as_bytes()
        var n = len(bytes_ref)
        if n == 0:
            raise Error("HttpError[URL_INVALID]: empty url")

        # ---- Find ':' for scheme.
        var colon_idx = -1
        var i = 0
        while i < n:
            if bytes_ref[i] == UInt8(ord(":")):
                colon_idx = i
                break
            i = i + 1
        if colon_idx <= 0:
            raise Error("HttpError[URL_INVALID]: missing scheme")
        # First char must be ALPHA.
        if not _is_alpha(bytes_ref[0]):
            raise Error("HttpError[URL_INVALID]: scheme must start with alpha")

        var scheme = String()
        var k = 0
        while k < colon_idx:
            scheme = scheme + chr(Int(_to_lower_ascii(bytes_ref[k])))
            k = k + 1

        # Only http/https accepted.
        if scheme != String("http") and scheme != String("https"):
            raise Error(
                "HttpError[URL_INVALID]: only http/https schemes supported"
            )

        # ---- "//" must follow.
        if colon_idx + 2 >= n:
            raise Error("HttpError[URL_INVALID]: missing authority")
        if (
            bytes_ref[colon_idx + 1] != UInt8(ord("/"))
            or bytes_ref[colon_idx + 2] != UInt8(ord("/"))
        ):
            raise Error("HttpError[URL_INVALID]: missing '//' after scheme")

        var auth_start = colon_idx + 3

        # ---- Find end of authority (first '/', '?', '#', or EOF).
        var auth_end = n
        var j = auth_start
        while j < n:
            var b = bytes_ref[j]
            if b == UInt8(ord("/")) or b == UInt8(ord("?")) or b == UInt8(ord("#")):
                auth_end = j
                break
            j = j + 1

        if auth_end == auth_start:
            raise Error("HttpError[URL_INVALID]: empty authority")

        # ---- Parse authority: [userinfo "@"] host [":" port]
        # Find '@' (for userinfo) — within [auth_start, auth_end).
        var at_idx = -1
        var p = auth_start
        while p < auth_end:
            if bytes_ref[p] == UInt8(ord("@")):
                at_idx = p
                break
            p = p + 1
        var userinfo = String()
        var host_start = auth_start
        if at_idx >= 0:
            userinfo = _slice(s, auth_start, at_idx)
            host_start = at_idx + 1

        # Host might be bracketed for IPv6. The IPv4/reg-name and IPv6
        # branches each assign `host`; declared outside to widen scope.
        var host: String
        var port_str_start = -1
        if (
            host_start < auth_end
            and bytes_ref[host_start] == UInt8(ord("["))
        ):
            # IPv6: find matching ']'.
            var close_bracket = -1
            var q = host_start + 1
            while q < auth_end:
                if bytes_ref[q] == UInt8(ord("]")):
                    close_bracket = q
                    break
                q = q + 1
            if close_bracket < 0:
                raise Error(
                    "HttpError[URL_INVALID]: unclosed IPv6 bracket"
                )
            host = _slice(s, host_start + 1, close_bracket)
            # Optional ":" port after ']'.
            if close_bracket + 1 < auth_end:
                if bytes_ref[close_bracket + 1] != UInt8(ord(":")):
                    raise Error(
                        "HttpError[URL_INVALID]: unexpected char after IPv6 host"
                    )
                port_str_start = close_bracket + 2
        else:
            # reg-name or IPv4: find LAST ':' for port separator.
            var last_colon = -1
            var r = host_start
            while r < auth_end:
                if bytes_ref[r] == UInt8(ord(":")):
                    last_colon = r
                r = r + 1
            if last_colon < 0:
                host = _slice(s, host_start, auth_end)
            else:
                host = _slice(s, host_start, last_colon)
                port_str_start = last_colon + 1

        if len(host.as_bytes()) == 0:
            raise Error("HttpError[URL_INVALID]: empty host")

        # ---- Port parse.
        var port: UInt16 = UInt16(0)
        if port_str_start > 0:
            if port_str_start >= auth_end:
                raise Error("HttpError[URL_INVALID]: empty port")
            var port_val = 0
            var t = port_str_start
            while t < auth_end:
                var b2 = bytes_ref[t]
                if not _is_digit(b2):
                    raise Error("HttpError[URL_INVALID]: non-digit in port")
                port_val = port_val * 10 + (Int(b2) - Int(ord("0")))
                if port_val > 65535:
                    raise Error("HttpError[URL_INVALID]: port out of range")
                t = t + 1
            port = UInt16(port_val)

        # ---- Path / query / fragment.
        var path = String("/")
        var query = String()
        var fragment = String()
        if auth_end < n:
            # Look for '?' and '#' boundaries within [auth_end, n).
            var qmark = -1
            var hashm = -1
            var u = auth_end
            while u < n:
                var bb = bytes_ref[u]
                if qmark < 0 and bb == UInt8(ord("?")):
                    qmark = u
                if hashm < 0 and bb == UInt8(ord("#")):
                    hashm = u
                u = u + 1
            var path_end = n
            if qmark >= 0:
                path_end = qmark
            elif hashm >= 0:
                path_end = hashm
            if path_end > auth_end:
                path = _slice(s, auth_end, path_end)
            if qmark >= 0:
                var query_end = n
                if hashm >= 0:
                    query_end = hashm
                query = _slice(s, qmark + 1, query_end)
            if hashm >= 0:
                fragment = _slice(s, hashm + 1, n)
        # An empty path is canonicalized to "/" per RFC 3986 §3.3 / §6.2.3.
        if len(path.as_bytes()) == 0:
            path = String("/")

        var url = Url()
        url.scheme = scheme^
        url.userinfo = userinfo^
        url.host = host^
        url.port = port
        url.path = path^
        url.query = query^
        url.fragment = fragment^
        return url^
