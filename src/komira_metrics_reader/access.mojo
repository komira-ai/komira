# =============================================================================
# komira_metrics_reader/access.mojo: WHO MAY READ THE METRICS. A hook the
#   embedding service supplies; the route asks it and nothing else.
# =============================================================================
#
# The same rules as komira_log_query's `LogReadAccess`, for the same reasons:
#
#   * The route takes the hook as a REQUIRED argument, so a mounted route has
#     always been handed a decision.
#   * Both hooks shipped here default to NO: `DenyMetricsReads` refuses
#     everyone; `MetricsHeaderTokenAccess` refuses everything while its header
#     name or its secret is empty, so a deployment that forgot the secret has
#     no readable metrics rather than open ones.
#   * No allow-everything hook ships. A service that wants open metrics writes
#     that one-line hook itself, where a reviewer sees it.
#   * A hook that raises is a NO.
#   * The hook sees the request, never the parsed query: it runs before any
#     argument is read.
#
# Metrics name a service's routes, its callers' status codes and its load; a
# read surface that is open whenever nobody configured it is open exactly when
# nobody is looking.
#
# Encapsulation: `HttpRequest` borrowed in, `Bool` out. No pointer.
# =============================================================================

from komira_http_core.codec.types import HttpRequest


trait MetricsReadAccess:
    """May this request read the metrics. True lets it through to argument
    checks and the read; False and a raise are both the route's one 404."""

    def allows(self, req: HttpRequest) raises -> Bool:
        ...


struct DenyMetricsReads(MetricsReadAccess, Copyable, Movable):
    """Refuses every request: the hook to pass while a service has no policy.
    The route then answers 404 to everyone, as if it were not mounted."""

    def __init__(out self):
        pass

    def allows(self, req: HttpRequest) raises -> Bool:
        return False


struct MetricsHeaderTokenAccess(MetricsReadAccess, Copyable, Movable):
    """Allows a request whose header `header` carries exactly `token`.

    Refuses everything while `header` or `token` is empty. The header name is
    matched lowercased (the request parser stores names lowercased); the token
    is compared byte for byte with no early exit.

    ⚠ The token is secret material: a service reads it from its secret store,
    never from its command line (`/proc/<pid>/cmdline` is world-readable)."""

    var _header: String
    var _token: String

    def __init__(out self, header: String, token: String):
        self._header = _ascii_lower(header)
        self._token = token

    def allows(self, req: HttpRequest) raises -> Bool:
        if self._header.byte_length() == 0:
            return False
        if self._token.byte_length() == 0:
            return False
        var presented = req.headers.get(self._header)
        if not presented:
            return False
        return _const_time_eq(presented.value(), self._token)


def _ascii_lower(s: String) -> String:
    var b = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(b)):
        var c = b[i]
        if c >= UInt8(ord("A")) and c <= UInt8(ord("Z")):
            out.append(c + UInt8(32))
        else:
            out.append(c)
    return String(unsafe_from_utf8=out^)


def _const_time_eq(a: String, b: String) -> Bool:
    """A length-checked compare with no early exit on the first differing
    byte."""
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    if len(ab) != len(bb):
        return False
    var diff = UInt8(0)
    for i in range(len(ab)):
        diff = diff | (ab[i] ^ bb[i])
    return diff == UInt8(0)
