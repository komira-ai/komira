# =============================================================================
# src/kci_pkg_upload/http_read.mojo — the one GET loop the registry
#   reads share: follow a redirect under `komira_http_client`'s redirect POLICY, and
#   never let a transport fault or an unfollowable redirect escape as a raise.
# =============================================================================
#
# THE LOOP IS HERE; THE POLICY IS NOT. Which statuses redirect, how a Location
# resolves, the hop budget, and which host may receive the credential are
# `komira_http_client/redirect_policy.mojo`'s decisions, shared with the OCI
# copier. The loop stays in this package, above `PkgTransport`, because a
# redirect must stay SCRIPTABLE: the falsifier is "queue a 302, queue the
# answer, assert over the recorded conversation".
#
# ⛔ THE CREDENTIAL GOES ONLY TO THE ORIGINAL HOST. A package file is commonly
# served from a different host than its index (a CDN, a signed storage URL);
# `authorization_for_hop` withholds the `Authorization` value from any hop
# whose host is not the original request's — never merely the previous hop's.
#
# ⛔ NEVER RAISES. A read's every answer is data (`outcome.mojo`): a transport
# fault, a refused redirect, and an exhausted hop budget come back as a result
# with `ok == False` and a detail, which the callers turn into UNKNOWN.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from komira_http_client.redirect_policy import (
    MAX_REDIRECT_HOPS,
    REDIRECT_REFUSED_EMPTY_HOST,
    REDIRECT_REFUSED_NO_LOCATION,
    REDIRECT_REFUSED_NO_PATH,
    REDIRECT_REFUSED_PLAINTEXT,
    REDIRECT_REFUSED_UNRESOLVABLE,
    RedirectTarget,
    authorization_for_hop,
    is_redirect_status,
    resolve_redirect_location,
)
from komira_http_core.codec.types import HTTP_METHOD_GET

from .outcome import withhold_if_echoes
from .transport import PkgRequest, PkgResponse, PkgTransport, try_exchange


struct GetResult(Movable, Deinitable):
    """The end of a GET chain. `ok == False` means there is no server answer
    to classify (a transport fault, an unfollowable redirect, a loop);
    `detail` says which. When `ok`, `response` is the final non-redirect
    answer and `host` / `path` are where it came from.

    Layout: owned values only. No pointer field."""

    var ok: Bool
    var response: PkgResponse
    var host: String
    var path: String
    var detail: String

    def __init__(
        out self,
        ok: Bool,
        var response: PkgResponse,
        var host: String,
        var path: String,
        var detail: String,
    ):
        self.ok = ok
        self.response = response^
        self.host = host^
        self.path = path^
        self.detail = detail^


def _refusal_text(kind: Int) -> String:
    if kind == REDIRECT_REFUSED_NO_LOCATION:
        return String("a redirect with no Location header")
    if kind == REDIRECT_REFUSED_PLAINTEXT:
        return String("a redirect to a plaintext http:// URL (refused, never upgraded)")
    if kind == REDIRECT_REFUSED_NO_PATH:
        return String("a redirect to a host with no path")
    if kind == REDIRECT_REFUSED_EMPTY_HOST:
        return String("a redirect with an empty host")
    return String("a redirect whose Location cannot be resolved without guessing")


def get_following_redirects[T: PkgTransport](
    mut transport: T,
    host: String,
    path: String,
    accept: String,
    authorization: String,
) -> GetResult:
    """GET `https://<host><path>`, following up to `MAX_REDIRECT_HOPS`
    redirects. `authorization` (EMPTY = anonymous) is carried only to hops on
    `host`. Never raises."""
    var cur_host = host.copy()
    var cur_path = path.copy()
    var hops = 0
    while True:
        var req = PkgRequest(HTTP_METHOD_GET, cur_host.copy(), cur_path.copy())
        if accept.byte_length() > 0:
            req.with_header(String("Accept"), accept.copy())
        req.with_authorization(authorization_for_hop(host, cur_host, authorization))
        var ex = try_exchange(transport, req)
        if not ex.ok:
            return GetResult(
                False,
                PkgResponse(0),
                cur_host^,
                cur_path^,
                withhold_if_echoes(
                    String("transport fault on GET ")
                    + req.host
                    + req.path
                    + String(": ")
                    + ex.fault,
                    authorization,
                ),
            )
        var resp = ex.response.copy()
        if not is_redirect_status(resp.status):
            return GetResult(True, resp^, cur_host^, cur_path^, String(""))
        if hops >= MAX_REDIRECT_HOPS:
            return GetResult(
                False,
                PkgResponse(resp.status),
                cur_host^,
                cur_path^,
                String("more than ")
                + String(MAX_REDIRECT_HOPS)
                + String(" redirects starting at ")
                + host
                + path,
            )
        var target = resolve_redirect_location(cur_host, resp.header(String("location")))
        if not target.is_resolved():
            return GetResult(
                False,
                PkgResponse(resp.status),
                cur_host^,
                cur_path^,
                String("HTTP ")
                + String(resp.status)
                + String(" from ")
                + cur_host
                + cur_path
                + String(" is ")
                + _refusal_text(target.kind),
            )
        cur_host = target.host.copy()
        cur_path = target.path.copy()
        hops += 1


def _strip_fragment(href: String) -> String:
    var hash = href.find(String("#"))
    if hash < 0:
        return href.copy()
    return String(href[byte=:hash])


def _remove_dot_segments(path: String) -> String:
    """RFC 3986 §5.2.4 over an absolute path (it starts with `/`): `.` is
    dropped, `..` removes the segment before it, and a path that ends in a
    `.`/`..` segment ends in `/`."""
    var parts = List[String]()
    var start = 1
    var n = path.byte_length()
    while True:
        var slash = path.find(String("/"), start)
        if slash < 0:
            parts.append(String(path[byte=start:n]))
            break
        parts.append(String(path[byte=start:slash]))
        start = slash + 1
    var out = List[String]()
    for i in range(len(parts)):
        var seg = parts[i].copy()
        var last = i == len(parts) - 1
        if seg == String(".."):
            if len(out) > 0:
                _ = out.pop()
            if last:
                out.append(String(""))
        elif seg == String("."):
            if last:
                out.append(String(""))
        else:
            out.append(seg^)
    var res = String("")
    for i in range(len(out)):
        res += String("/") + out[i]
    if res.byte_length() == 0:
        return String("/")  # cov: unreachable the last segment always appends one entry, so res is never empty
    return res^


def resolve_index_href(page_host: String, page_path: String, href: String) -> RedirectTarget:
    """Resolve a file `href` found on an index page at
    `https://<page_host><page_path>` (PEP 503 / PEP 691 allow a relative
    URL). The fragment (`#sha256=…`) is dropped.

      `https://h/p`, `//h/p`, `/p`   — as `resolve_redirect_location` resolves
                                       a Location (plaintext refused);
      `../x`, `x`                    — merged with the page's directory and
                                       dot-segments removed (RFC 3986 §5.2);
      another scheme (`data:`, …)    — refused (UNRESOLVABLE)."""
    var h = _strip_fragment(href)
    if (
        h.startswith(String("https://"))
        or h.startswith(String("http://"))
        or h.startswith(String("/"))
        or h.byte_length() == 0
    ):
        return resolve_redirect_location(page_host, h)
    # A relative reference's first segment cannot contain `:` (RFC 3986 §4.2),
    # so a colon before the first `/` is a scheme we do not fetch.
    var colon = h.find(String(":"))
    var first_slash = h.find(String("/"))
    if colon >= 0 and (first_slash < 0 or colon < first_slash):
        return RedirectTarget(REDIRECT_REFUSED_UNRESOLVABLE, String(""), String(""))
    var dir_end = page_path.rfind(String("/"))
    var base_dir = String("/")
    if dir_end >= 0:
        base_dir = String(page_path[byte = : dir_end + 1])
    var query = String("")
    var rel = h.copy()
    var q = h.find(String("?"))
    if q >= 0:
        query = String(h[byte=q:])
        rel = String(h[byte=:q])
    return resolve_redirect_location(
        page_host, _remove_dot_segments(base_dir + rel) + query
    )
