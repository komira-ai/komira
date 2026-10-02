# =============================================================================
# src/komira_http/client/redirect.mojo — RedirectLayer
# =============================================================================
#
#
#   "Redirect-following is a RedirectLayer (an HttpLayer), not a built-in
#    feature — a redirect re-invokes the request against a new Url, which
#    is a Layer operation. The default stack does NOT include RedirectLayer
#    — 3xx following is opt-in. Cloud object stores and RPC endpoints
#    rarely redirect; a silent redirect can leak credentials to an
#    unexpected host."
#
# Policy:
#   * Follow 301/302/303/307/308 up to max_redirects.
#   * 301/302 on a non-GET/HEAD method are surfaced to the caller rather
#     than guessed (RFC 7231 §6.4 — application-dependent).
#   * 303 → convert to GET (RFC 7231 §6.4.4).
#   * 307/308 → preserve method + headers + body bytes.
#   * **Cross-origin Authorization stripping**: if the redirect URL's
#     origin (scheme+host+port) differs from the original request's
#     origin → strip:
#       - Authorization
#       - Cookie / Set-Cookie
#       - Proxy-Authorization
#       - X-Amz-Security-Token / X-Goog-Api-Key / X-Goog-User-Project
#       - WWW-Authenticate (mirror)
#   * Loop detection: if a URL is seen twice in one chain → raise.
#   * max_redirects exceeded → raise HttpError.
#
# Like RetryLayer, This version supports ClientRequest[EmptyBody] in its
# replay path. Trait `call[B]` is no-replay pass-through for
# B != EmptyBody.
#
# Encapsulation discipline:
#   * ZERO UnsafePointer in any signature.
#   * ZERO wildcard origins.
#   * ZERO `unsafe_from_address`.
#   * ZERO `take_pointee`.
#   * ZERO new ArcPointer.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_http.client.body import EmptyBody, RequestBody
from komira_http.client.header_map import HeaderMap, sab_to_string
# The status predicate is the ONE this package states (`redirect_policy.mojo`);
# the credential rule below is this layer's own (origin-scoped, strip-once).
from komira_http.client.redirect_policy import is_redirect_status
from komira_http.client.response_body import BufferedResponseBody
from komira_http.client.service import (
    ClientRequest,
    HttpLayer,
    HttpService,
)
from komira_http.client.state_machine import ClientResponse
from komira_http.client.url import Url
from komira_http.codec.types import HttpMethod
from komira_http.transport.io_stream import Connector


# =============================================================================
# §1 — Sensitive-header table.
# =============================================================================


comptime _SENSITIVE_HEADER_AUTHORIZATION: String = "Authorization"
comptime _SENSITIVE_HEADER_COOKIE: String = "Cookie"
comptime _SENSITIVE_HEADER_SET_COOKIE: String = "Set-Cookie"
comptime _SENSITIVE_HEADER_PROXY_AUTHORIZATION: String = "Proxy-Authorization"
comptime _SENSITIVE_HEADER_WWW_AUTHENTICATE: String = "WWW-Authenticate"
# Cloud credentials that ride in a header rather than `Authorization`.
comptime _SENSITIVE_HEADER_AMZ_SECURITY_TOKEN: String = "X-Amz-Security-Token"
comptime _SENSITIVE_HEADER_GOOG_API_KEY: String = "X-Goog-Api-Key"
comptime _SENSITIVE_HEADER_GOOG_USER_PROJECT: String = "X-Goog-User-Project"


def _strip_sensitive_headers(mut headers: HeaderMap):
    """Remove the cross-origin sensitive headers in place. HeaderMap
    treats names case-insensitively, so we delete by canonical name."""
    headers.remove(_SENSITIVE_HEADER_AUTHORIZATION)
    headers.remove(_SENSITIVE_HEADER_COOKIE)
    headers.remove(_SENSITIVE_HEADER_SET_COOKIE)
    headers.remove(_SENSITIVE_HEADER_PROXY_AUTHORIZATION)
    headers.remove(_SENSITIVE_HEADER_WWW_AUTHENTICATE)
    headers.remove(_SENSITIVE_HEADER_AMZ_SECURITY_TOKEN)
    headers.remove(_SENSITIVE_HEADER_GOOG_API_KEY)
    headers.remove(_SENSITIVE_HEADER_GOOG_USER_PROJECT)


# =============================================================================
# §2 — Origin comparison.
# =============================================================================


def _urls_same_origin(ref a: Url, ref b: Url) -> Bool:
    """Per RFC 6454: two origins are same iff scheme + host + port match."""
    if String(a.scheme) != String(b.scheme):
        return False
    if String(a.host) != String(b.host):
        return False
    if a.effective_port() != b.effective_port():
        return False
    return True


# =============================================================================
# §3 — Status-code classification.
# =============================================================================


@always_inline
def _method_is_get_or_head(method: HttpMethod) -> Bool:
    var name = method.name()
    return name == String("GET") or name == String("HEAD")


# =============================================================================
# §4 — Location header extraction.
# =============================================================================


def _extract_location(ref headers: HeaderMap) raises -> Url:
    """Extract the Location header value, parse as Url.

    Option C migration: `get_view` returns the SAB; `sab_to_string`
    materializes once at the boundary. `Url.parse` genuinely
    requires a String input — this is the canonical String-boundary
    site.
    """
    var loc_opt = headers.get_view(String("Location"))
    if not loc_opt.__bool__():
        raise Error(
            "HttpError[PROTOCOL_STATUS]: 3xx response missing Location "
            "header"
        )
    var loc_str = sab_to_string(loc_opt.value())
    var parsed = Url.parse(loc_str^)
    return parsed^


# =============================================================================
# §5 — Url ↔ String canonicalization.
# =============================================================================


def _url_redacted(ref u: Url) -> String:
    """`scheme://host[:port]/path` only, for error text: no userinfo and no
    query, because a presigned `Location` carries its signature in the query
    and an error message ends up in logs."""
    var out = String(u.scheme) + String("://") + String(u.host)
    var port_val = u.effective_port()
    var default_port: UInt16 = UInt16(443) if u.is_https() else UInt16(80)
    if port_val != default_port:
        out = out + String(":") + String(Int(port_val))
    return out + String(u.path)


def _url_string(ref u: Url) -> String:
    """Build a canonical scheme://host[:port]/path[?query] string for
    same-URL comparison + Url.parse round-trip. Excludes fragment
    (RFC 7230 §5.1 — fragments are not on the wire)."""
    var out = String(u.scheme) + String("://")
    if u.userinfo.byte_length() > 0:
        out = out + String(u.userinfo) + String("@")
    out = out + String(u.host)
    var port_val = u.effective_port()
    var default_port: UInt16 = UInt16(443) if u.is_https() else UInt16(80)
    if port_val != default_port:
        out = out + String(":") + String(Int(port_val))
    out = out + String(u.path)
    if u.query.byte_length() > 0:
        out = out + String("?") + String(u.query)
    return out^


# =============================================================================
# §6 — HeaderMap clone.
# =============================================================================


def _clone_header_map_internal(ref src: HeaderMap) raises -> HeaderMap:
    """Deep-copy a HeaderMap. `raises` propagates from
    HeaderMap.append (POC-C SAB variant; SAB.slice raises on
    bounds error — practically unreachable here)."""
    var out = HeaderMap()
    var n = src.len()
    var i = 0
    while i < n:
        var entry = src.entry_at(i)
        out.append(String(entry.name), String(entry.value))
        i = i + 1
    return out^


def _clone_url_internal(ref src: Url) -> Url:
    """Deep-copy a Url. 4-arg ctor + post-construction field assignment."""
    var out = Url(
        scheme=String(src.scheme),
        host=String(src.host),
        port=src.port,
        path=String(src.path),
    )
    out.userinfo = String(src.userinfo)
    out.query = String(src.query)
    out.fragment = String(src.fragment)
    return out^


# =============================================================================
# §7 — RedirectLayer.
# =============================================================================


struct RedirectLayer[Inner: HttpService](
    HttpService, HttpLayer, Movable, Deinitable,
):
    """ RedirectLayer.

    Construction:
      `RedirectLayer.wrap(inner, max_redirects)`.

    On `call_empty`:
      1. Stash (method, url, headers, request_bytes) of current request.
      2. Invoke inner.call.
      3. If status is in {301,302,303,307,308} AND hops < max_redirects:
         a. Parse Location → new Url.
         b. 301/302 on non-GET/HEAD: surface unchanged to caller.
         c. Detect loop (URL already seen) → raise.
         d. If new URL's origin differs from previous → strip sensitive
            headers.
         e. 303 → method=GET (else keep original method).
         f. Reconstruct ClientRequest; loop.
      4. Else: return response.
      5. hops > max_redirects → raise.
    """

    var _inner: Self.Inner
    var _max_redirects: UInt32
    var _last_hops: UInt32

    @staticmethod
    def wrap(
        var inner: Self.Inner, max_redirects: UInt32,
    ) -> RedirectLayer[Self.Inner]:
        return RedirectLayer[Self.Inner](
            _inner=inner^,
            _max_redirects=max_redirects,
            _last_hops=UInt32(0),
        )

    def __init__(
        out self,
        var _inner: Self.Inner,
        _max_redirects: UInt32,
        _last_hops: UInt32,
    ):
        self._inner = _inner^
        self._max_redirects = _max_redirects
        self._last_hops = _last_hops

    def layer_name(self) -> String:
        return String("redirect")

    @always_inline
    def last_hops(self) -> UInt32:
        """Diagnostic: how many redirects the most recent call followed.
        0 = no redirect; 1 = one redirect; ..."""
        return self._last_hops

    def call[RT: Runtime, C: Connector, B: RequestBody](
        mut self,
        var req: ClientRequest[B],
        mut connector: C,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[BufferedResponseBody]:
        """HttpService.call trait method (pass-through for
        B != EmptyBody). For redirect-following calls, use
        `call_empty` directly."""
        self._last_hops = UInt32(0)
        return self._inner.call[RT, C, B](req^, connector, reactor)

    def call_empty[RT: Runtime, C: Connector](
        mut self,
        var req: ClientRequest[EmptyBody],
        mut connector: C,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[BufferedResponseBody]:
        """The redirect-following call. See struct docstring."""
        self._last_hops = UInt32(0)
        var max_hops = Int(self._max_redirects)

        # Per-iter stash. We deep-copy out of `req` before consuming.
        var prev_method = req.method
        # ⛔ CARRIED ACROSS EVERY HOP, FOR THE SAME REASON THE RETRY LAYER
        # CARRIES IT: each hop builds a NEW `ClientRequest`, and a budget left
        # out of the rebuild is a deadline that binds on hop 0 and on NO hop
        # after it — the shape where the first request is bounded and the
        # redirect that actually wedges is not.
        #
        # ⚠ AND THE SCOPE, STATED HONESTLY RATHER THAN OVERCLAIMED: this is a
        # RELATIVE budget, so each hop gets the FULL number and the chain
        # total is bounded by `hop_budget x max_hops`, not by the budget. A
        # true chain-total would need an ABSOLUTE deadline, which the carrier
        # deliberately is not (a layer's injected `Clock` has its own epoch;
        # see `ClientRequest._request_budget_us`). What binds the total today
        # is `_MAX_REDIRECT_HOPS` times this number plus `TimeoutLayer`'s
        # post-call check — a real bound, and a looser one than a reader
        # would assume from "the request carries its deadline".
        var prev_budget_us = req.request_budget_us()
        var prev_url = _clone_url_internal(req.url)
        var prev_headers = _clone_header_map_internal(req.headers)
        var prev_request_bytes = _clone_bytes_internal(req.request_bytes)
        var seen_urls = List[String]()
        seen_urls.append(_url_string(prev_url))

        var current_req = req^
        var hop = 0
        while True:
            # Invoke inner.
            var resp = self._inner.call[
                RT, C, EmptyBody
            ](current_req^, connector, reactor)
            var status_int = Int(resp.status)

            # Non-redirect → return.
            if not is_redirect_status(status_int):
                self._last_hops = UInt32(hop)
                return resp^

            # max_redirects guard.
            if hop >= max_hops:
                raise Error(
                    "HttpError[PROTOCOL_STATUS]: redirect chain exceeded "
                    "max_redirects=" + String(max_hops)
                )

            # 301/302 on non-GET/non-HEAD → surface to caller.
            if status_int == 301 or status_int == 302:
                if not _method_is_get_or_head(prev_method):
                    self._last_hops = UInt32(hop)
                    return resp^

            # Parse Location.
            var new_url = _extract_location(resp.headers)
            var new_url_str = _url_string(new_url)

            # Never follow an https -> http downgrade: a 307/308 would replay
            # the request (body included) in cleartext.
            if prev_url.is_https() and not new_url.is_https():
                raise Error(
                    "HttpError[PROTOCOL_STATUS]: redirect from https to "
                    "http refused (scheme downgrade) to "
                    + _url_redacted(new_url)
                )

            # Loop detection.
            var seen_n = seen_urls.__len__()
            var seen_i = 0
            while seen_i < seen_n:
                if seen_urls[seen_i] == new_url_str:
                    raise Error(
                        "HttpError[PROTOCOL_STATUS]: redirect loop "
                        "detected at " + _url_redacted(new_url)
                    )
                seen_i = seen_i + 1
            seen_urls.append(new_url_str)

            # Cross-origin → strip sensitive headers.
            var same_origin = _urls_same_origin(prev_url, new_url)
            var new_headers = _clone_header_map_internal(prev_headers)
            if not same_origin:
                _strip_sensitive_headers(new_headers)

            # Method handling: 303 → GET; else preserve.
            var new_method = prev_method
            var new_request_bytes = _clone_bytes_internal(prev_request_bytes)
            if status_int == 303:
                new_method = HttpMethod.get()
                # 303 forces method to GET — body is dropped.
                new_request_bytes = List[UInt8]()

            # Build new ClientRequest.
            current_req = ClientRequest[EmptyBody](
                method=new_method,
                url=_clone_url_internal(new_url),
                headers=new_headers^,
                request_bytes=new_request_bytes^,
                body=EmptyBody.new(),
            )
            current_req.set_request_budget_us(prev_budget_us)

            # Update per-iter stash (for next iter's origin compare +
            # in case the next response is non-redirect).
            prev_method = new_method
            var nu = _clone_url_internal(new_url)
            prev_url = nu^
            prev_headers = _clone_header_map_internal(current_req.headers)
            prev_request_bytes = _clone_bytes_internal(current_req.request_bytes)

            hop = hop + 1


# =============================================================================
# §8 — Bytes clone helper.
# =============================================================================


def _clone_bytes_internal(ref src: List[UInt8]) -> List[UInt8]:
    """Deep-copy a List[UInt8]."""
    var out = List[UInt8]()
    var n = src.__len__()
    var i = 0
    while i < n:
        out.append(src[i])
        i = i + 1
    return out^
