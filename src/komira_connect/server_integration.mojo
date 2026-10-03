# =============================================================================
# server_integration.mojo — ConnectService ↔ Router bridge
# =============================================================================
#
# Per service.mojo §2 doc on ConnectService: "The HttpServer integration
# layer registers a wildcard route for `/{pkg}.{svc}/...` patterns and
# delegates incoming requests via `handle_request`." This file is that
# integration layer.
#
# Bridge model (mirrors serve_h2.mojo's `_build_and_dispatch_request`):
#   * The `komira_http.Router` dispatches by INTEGER handler-ID — a
#     `match_route(...)` returns `Optional[Int]`, an index into the
#     caller's handler table. The Router does NOT own the handler; the
#     caller branches on the returned id. serve_h2 does exactly this:
#     `var hid = router.match_route(method, path, params)` then
#     `if hid: ...emit response...`.
#   * So the wildcard → ConnectService bridge registers ONE wildcard
#     route (`/*`) whose handler-id is a known sentinel
#     (`CONNECT_SERVICE_HANDLER_ID`). At dispatch time, when the matched
#     id equals that sentinel, we delegate to
#     `ConnectService.handle_request(path, content_type, body)` and return
#     its DispatchResult. A miss (no route matched, or a non-Connect id)
#     yields the NOT_FOUND DispatchResult — the same result
#     `handle_request` produces for an unregistered method path.
#
# This reuses the existing integer-handler-ID dispatch mechanism — it does
# NOT invent a new one.
#
# Encapsulation: NO UnsafePointer in any public sig; ZERO wildcard origins;
# ZERO `unsafe_from_address`; ZERO new ArcPointer. The `ref [origin]`
# bindings carry concrete origins.
# =============================================================================

from std.collections.dict import Dict

from komira_http_core.codec import HttpMethod
from komira_http_server.routing import Router

from .dispatch import DispatchResult, codec_id_for_content_type
from .service import ConnectService, _make_not_found_result


# =============================================================================
# §1 — The handler-ID sentinel for "this route is the Connect service".
# =============================================================================
#
# The Router dispatches by integer id; the caller owns the meaning of each
# id. We reserve one well-known id for the Connect wildcard route. Callers
# that also register non-Connect routes (e.g. /healthz) should use ids that
# do NOT collide with this sentinel.

comptime CONNECT_SERVICE_HANDLER_ID: Int = 0x7C0_0EC7  # "connect" — a distinctive
"""Sentinel handler-id used by `register_connect_wildcard` for the `/*`
route bound to a ConnectService. `dispatch_connect_request` recognizes a
match on this id and delegates to `ConnectService.handle_request`."""


# =============================================================================
# §2 — Wildcard-route registration.
# =============================================================================


def register_connect_wildcard(mut router: Router) raises -> Int:
    """Register the Connect-RPC wildcard route on `router`.

    Adds a POST `/*` route (Connect/gRPC RPC calls are POST) whose
    handler-id is `CONNECT_SERVICE_HANDLER_ID`. Returns that id so the
    caller can match against it (mirrors the serve_h2 id-branch pattern).

    Connect RPC paths have the shape `/{pkg}.{svc}/{method}` — every such
    path is captured by the tail `/*` wildcard (the wildcard matches any
    suffix per `Router._try_match`). The per-method routing is then done
    inside `ConnectService` by exact path lookup (`has_method`), so the
    Router only needs the single coarse wildcard entry.

    Raises if the route conflicts with an existing registration on the
    same (method, pattern).
    """
    router.add(HttpMethod.post(), "/*", CONNECT_SERVICE_HANDLER_ID)
    return CONNECT_SERVICE_HANDLER_ID


# =============================================================================
# §3 — The dispatch bridge.
# =============================================================================


def dispatch_connect_request(
    imm service: ConnectService,
    ref router: Router,
    path: String,
    content_type: String,
    request_body: Span[UInt8, _],
) -> DispatchResult:
    """Route one inbound request through `router` to `service`.

    Resolves the route via `router.match_route(POST, path)`. If the match
    lands on the Connect wildcard (`CONNECT_SERVICE_HANDLER_ID`), delegates
    to `service.handle_request(path, content_type, request_body)` and
    returns its DispatchResult. Otherwise (no route, or a non-Connect id)
    returns the NOT_FOUND DispatchResult — the same shape
    `handle_request` produces for an unregistered method path.

    Connect/gRPC RPC calls are always POST; the bridge matches on POST.
    """
    var params = Dict[String, String]()
    var hid = router.match_route(HttpMethod.post(), path, params)
    if hid and hid.value() == CONNECT_SERVICE_HANDLER_ID:
        # Wildcard hit — delegate per-method resolution to the service.
        return service.handle_request(path, content_type, request_body)
    # No Connect route matched. Surface a NOT_FOUND result keyed on the
    # resolved codec (so the error body is in the right wire shape).
    var codec_id = codec_id_for_content_type(content_type)
    return _make_not_found_result(codec_id, path)
