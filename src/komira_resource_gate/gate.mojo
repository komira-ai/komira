# =============================================================================
# gate.mojo — ResourceCatalog (what an application declares) and
# ResourceAuthzGate (the dispatcher that enforces it in front of the
# application's own dispatcher).
# =============================================================================
#
# An application declares one pure function, `Catalog.route(method, path)`,
# from a request to a `RouteDecision`, and binds an `AuthzPort`. The gate does
# the rest, per request, in this order:
#
#   1. ROUTE. `Catalog.route` is pure; the query string is not an input, so a
#      client cannot choose its own requirement with a parameter.
#   2. PUBLIC: the inner dispatcher runs with `ctx.principal` cleared and the
#      gate's attributes removed. A public route needs no credential and
#      trusts none.
#   3. Not GOVERNED: 403. This is the deny-by-default arm. The test is
#      affirmative (`is_governed()`), so an outcome kind added later is
#      refused here.
#   4. GOVERNED without a principal, or with an empty subject: 401 with
#      `WWW-Authenticate: Bearer` (RFC 6750 section 3.1, no error code).
#      Authentication itself happens upstream: a middleware sets
#      `ctx.principal` from a verified credential.
#   5. `Authz.check(principal, action, resource)`: False is 403; a raise is
#      503 with `Retry-After`, so a client can tell an outage from a denial.
#      Neither is ever served.
#   6. ALLOWED: the inner dispatcher runs with the caller's `ctx`, plus the
#      authorized action, resource kind and resource id in `ctx.attributes`
#      under the `GATE_ATTRIBUTE_*` keys (replacing any earlier value). A
#      handler that acts on those values acts on exactly what was authorized.
#
# Every refusal has a fixed text body and `Cache-Control: no-store`. A route
# that is not declared and a route declared as refused give the same 403, and
# the 403 for a denial is the same whatever the resource, so the gate does not
# say whether a resource exists.
#
# `dispatch` (the path without a middleware chain) runs `dispatch_with_ctx`
# with an empty context, so a governed route answers 401 there.
#
# Encapsulation: the gate owns `Inner` and `Authz` by value; `Catalog` is a
# type parameter with a static surface, so the gate holds no catalog value and
# every request is routed by the same table. No pointer, no wildcard origin.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_authz_api import AuthzPort

from komira_http_core.codec.types import HttpRequest, HttpResponse
from komira_http_server.dispatch import CtxRequestDispatcher, RequestDispatcher
from komira_http_server.middleware import Claims, Principal, RequestContext

from .route_decision import ResourceRequirement, RouteDecision


comptime GATE_ATTRIBUTE_ACTION: String = "authz.action"
"""The `ctx.attributes` key holding the authorized action's name."""

comptime GATE_ATTRIBUTE_RESOURCE_KIND: String = "authz.resource.kind"
"""The `ctx.attributes` key holding the authorized resource's kind."""

comptime GATE_ATTRIBUTE_RESOURCE_ID: String = "authz.resource.id"
"""The `ctx.attributes` key holding the authorized resource's id (empty for
the kind as a whole)."""

comptime UNAUTHORIZED_BODY: String = "unauthorized\n"
comptime FORBIDDEN_BODY: String = "forbidden\n"
comptime AUTHZ_UNAVAILABLE_BODY: String = "authorization unavailable\n"

comptime AUTHZ_UNAVAILABLE_RETRY_AFTER_S: Int = 1
"""The `Retry-After` seconds on a 503 for an unavailable decision."""


trait ResourceCatalog:
    """What an application declares to be gated: one pure function from a
    request's method and path to a `RouteDecision`. Pure means no store, no
    clock and no I/O, so the whole surface is testable without a server. A
    request that matches nothing must yield `RouteDecision()` (DENY);
    `ResourceRouteTable.route` does, and is the usual body."""

    @staticmethod
    def route(method: String, path: String) -> RouteDecision:
        """The decision for a request with `method` (`GET`) and `path`."""
        ...


def _refusal(status: Int, text: String) -> HttpResponse:
    """`status` with the fixed text body `text`, never cached."""
    var r = HttpResponse(status=Int32(status))
    r.headers[String("content-type")] = String("text/plain; charset=utf-8")
    r.headers[String("cache-control")] = String("no-store")
    var body = List[UInt8]()
    body.extend(Span(text.as_bytes()))
    r.headers[String("content-length")] = String(len(body))
    r.body = body^
    return r^


def unauthorized_response() -> HttpResponse:
    """401, `WWW-Authenticate: Bearer`, body `UNAUTHORIZED_BODY`."""
    var r = _refusal(401, UNAUTHORIZED_BODY)
    r.headers[String("www-authenticate")] = String("Bearer")
    return r^


def forbidden_response() -> HttpResponse:
    """403, body `FORBIDDEN_BODY`."""
    return _refusal(403, FORBIDDEN_BODY)


def authz_unavailable_response() -> HttpResponse:
    """503, `Retry-After: AUTHZ_UNAVAILABLE_RETRY_AFTER_S`, body
    `AUTHZ_UNAVAILABLE_BODY`."""
    var r = _refusal(503, AUTHZ_UNAVAILABLE_BODY)
    r.headers[String("retry-after")] = String(AUTHZ_UNAVAILABLE_RETRY_AFTER_S)
    return r^


def _is_gate_attribute(key: String) -> Bool:
    return (
        key == GATE_ATTRIBUTE_ACTION
        or key == GATE_ATTRIBUTE_RESOURCE_KIND
        or key == GATE_ATTRIBUTE_RESOURCE_ID
    )


def _public_context(ctx: RequestContext) -> RequestContext:
    """`ctx` without a principal and without the gate's attributes."""
    var out = ctx.copy()
    out.principal = Optional[Principal]()
    var kept = Claims()
    for i in range(ctx.attributes.len()):
        var key = ctx.attributes.key_at(i)
        if not _is_gate_attribute(key):
            kept.set(key, ctx.attributes.value_at(i))
    out.attributes = kept^
    return out^


def _allowed_context(
    ctx: RequestContext, requirement: ResourceRequirement
) -> RequestContext:
    """`ctx` with the authorized action and resource in its attributes."""
    var out = ctx.copy()
    out.attributes.set(GATE_ATTRIBUTE_ACTION, requirement.action.name)
    out.attributes.set(
        GATE_ATTRIBUTE_RESOURCE_KIND, requirement.resource.kind
    )
    out.attributes.set(GATE_ATTRIBUTE_RESOURCE_ID, requirement.resource.id)
    return out^


def _authenticated(ctx: RequestContext) -> Bool:
    """True iff `ctx` carries a principal with a non-empty subject."""
    if not ctx.principal:
        return False
    return ctx.principal.value().subject.byte_length() > 0


struct ResourceAuthzGate[
    Inner: CtxRequestDispatcher,
    Catalog: ResourceCatalog,
    Authz: AuthzPort,
](Movable, RequestDispatcher, CtxRequestDispatcher):
    """A dispatcher that authorizes every request against what `Catalog`
    declares, through `Authz`, before `Inner` sees it (module header)."""

    var _inner: Self.Inner
    var _authz: Self.Authz

    def __init__(out self, var inner: Self.Inner, var authz: Self.Authz):
        self._inner = inner^
        self._authz = authz^

    def inner(mut self) -> ref [self._inner] Self.Inner:
        """The wrapped dispatcher, for the code that owns the gate (a serve
        loop that drives it between requests). A request cannot reach it."""
        return self._inner

    def authz(mut self) -> ref [self._authz] Self.Authz:
        """The bound authorization port, for the code that owns the gate."""
        return self._authz

    def into_inner(deinit self) -> Self.Inner:
        """The wrapped dispatcher; consumes the gate."""
        return self._inner^

    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        """The path without a middleware chain: an empty context, so no
        governed route is served."""
        var ctx = RequestContext.new()
        return self.dispatch_with_ctx[RT](reactor, req, ctx)

    def dispatch_with_ctx[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        mut req: HttpRequest,
        ctx: RequestContext,
    ) raises -> HttpResponse:
        var decision = Self.Catalog.route(req.method.name(), req.path)

        if decision.is_public():
            var public_ctx = _public_context(ctx)
            return self._inner.dispatch_with_ctx[RT](reactor, req, public_ctx)

        if not decision.is_governed():
            return forbidden_response()

        var requirement = decision.requirement()

        if not _authenticated(ctx):
            return unauthorized_response()

        var allowed: Bool
        try:
            allowed = self._authz.check[RT](
                reactor,
                ctx.principal.value(),
                requirement.action,
                requirement.resource,
            )
        except:
            return authz_unavailable_response()
        if not allowed:
            return forbidden_response()

        var allowed_ctx = _allowed_context(ctx, requirement)
        return self._inner.dispatch_with_ctx[RT](reactor, req, allowed_ctx)
