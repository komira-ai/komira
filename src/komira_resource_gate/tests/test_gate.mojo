# =============================================================================
# test_gate.mojo — ResourceAuthzGate: the order route, public, deny,
# authenticate, decide; what reaches the inner dispatcher; the three refusals.
# =============================================================================
#
# A recording `AuthzPort` (allow, deny or raise) and a recording inner
# dispatcher show what the gate asked and what it let through. Defects each
# test catches:
#   * an unrouted or refused path reaches the inner dispatcher or the port;
#   * a missing row is served as public;
#   * a public route forwards the caller's principal or a forged gate
#     attribute;
#   * an anonymous request to an unrouted or refused path is challenged
#     (401) instead of refused (403);
#   * a governed route is served, or the port asked, without a principal or
#     with an empty subject;
#   * a one-byte subject is refused as if it were empty;
#   * the port is asked about the wrong subject, action, kind or id;
#   * a denial is served, or answered as anything but the exact 403;
#   * a port that raises is served, read as a denial (403), or answered
#     without `Retry-After`;
#   * the inner dispatcher sees a forged gate attribute instead of what was
#     authorized;
#   * the path without a middleware chain serves a governed route.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK, Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime
from komira_authz_api import AuthzAction, AuthzPort, AuthzResource
from komira_http_core.codec.types import HttpMethod, HttpRequest, HttpResponse
from komira_http_server.dispatch import CtxRequestDispatcher, RequestDispatcher
from komira_http_server.middleware import Principal, RequestContext
from komira_resource_gate import (
    GATE_ATTRIBUTE_ACTION,
    GATE_ATTRIBUTE_RESOURCE_ID,
    GATE_ATTRIBUTE_RESOURCE_KIND,
    ResourceAuthzGate,
    ResourceCatalog,
    ResourceRouteTable,
    RouteDecision,
    RouteRule,
)

comptime RT = BlockingRuntime[NoopSink]

comptime MODE_ALLOW = 0
comptime MODE_DENY = 1
comptime MODE_RAISE = 2


struct _Catalog(ResourceCatalog):
    @staticmethod
    def route(method: String, path: String) -> RouteDecision:
        var rules = List[RouteRule]()
        rules.append(RouteRule.public_route(String("GET"), String("/health")))
        rules.append(
            RouteRule.deny_route(
                String("DELETE"), String("/repos/{repo}"), String("not here")
            )
        )
        rules.append(
            RouteRule.governed(
                String("GET"),
                String("/repos/{repo}"),
                String("repo"),
                String("repo"),
                AuthzAction.read(),
            )
        )
        rules.append(
            RouteRule.on_kind(
                String("POST"), String("/repos"), String("repo"), AuthzAction.write()
            )
        )
        return ResourceRouteTable(rules^).route(method, path)


struct _RecordingAuthz(AuthzPort):
    var mode: Int
    var calls: Int
    var subject: String
    var action: String
    var kind: String
    var id: String

    def __init__(out self, mode: Int):
        self.mode = mode
        self.calls = 0
        self.subject = String("")
        self.action = String("")
        self.kind = String("")
        self.id = String("")

    def check[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        principal: Principal,
        action: AuthzAction,
        resource: AuthzResource,
    ) raises -> Bool:
        self.calls += 1
        self.subject = principal.subject
        self.action = action.name
        self.kind = resource.kind
        self.id = resource.id
        if self.mode == MODE_RAISE:
            raise Error("decision unavailable")
        return self.mode == MODE_ALLOW


struct _Inner(Movable, RequestDispatcher, CtxRequestDispatcher):
    var reached: Int
    var had_principal: Bool
    var attr_action: String
    var attr_kind: String
    var attr_id: String
    var attr_other: String

    def __init__(out self):
        self.reached = 0
        self.had_principal = False
        self.attr_action = String("")
        self.attr_kind = String("")
        self.attr_id = String("")
        self.attr_other = String("")

    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
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
        self.reached += 1
        self.had_principal = Bool(ctx.principal)
        self.attr_action = ctx.attributes.get(GATE_ATTRIBUTE_ACTION).or_else(
            String("<unset>")
        )
        self.attr_kind = ctx.attributes.get(
            GATE_ATTRIBUTE_RESOURCE_KIND
        ).or_else(String("<unset>"))
        self.attr_id = ctx.attributes.get(GATE_ATTRIBUTE_RESOURCE_ID).or_else(
            String("<unset>")
        )
        self.attr_other = ctx.attributes.get(String("trace")).or_else(
            String("<unset>")
        )
        return HttpResponse.ok(String("served"))


comptime Gate = ResourceAuthzGate[_Inner, _Catalog, _RecordingAuthz]


def _gate(mode: Int) -> Gate:
    return Gate(_Inner(), _RecordingAuthz(mode))


def _req(method: HttpMethod, path: String) -> HttpRequest:
    return HttpRequest(method, path)


def _ctx(subject: String) raises -> RequestContext:
    """A context as an authentication middleware leaves it, plus a forged
    value under every gate attribute and one unrelated attribute."""
    var ctx = RequestContext.new()
    ctx.principal = Optional[Principal](
        Principal(scheme=String("jwt"), subject=subject)
    )
    ctx.attributes.set(GATE_ATTRIBUTE_ACTION, String("forged"))
    ctx.attributes.set(GATE_ATTRIBUTE_RESOURCE_KIND, String("forged"))
    ctx.attributes.set(GATE_ATTRIBUTE_RESOURCE_ID, String("forged"))
    ctx.attributes.set(String("trace"), String("t-1"))
    return ctx^


def _anonymous() -> RequestContext:
    return RequestContext.new()


def _body(resp: HttpResponse) -> String:
    var s = String("")
    for i in range(len(resp.body)):
        s += chr(Int(resp.body[i]))
    return s^


def _header(resp: HttpResponse, name: String) raises -> String:
    if name in resp.headers:
        return resp.headers[name]
    return String("<absent>")


def _assert_refusal(
    resp: HttpResponse, status: Int, body: String, what: String
) raises:
    assert_equal(Int(resp.status), status, what)
    assert_equal(_body(resp), body, what)
    assert_equal(_header(resp, "cache-control"), "no-store", what)
    assert_equal(
        _header(resp, "content-type"), "text/plain; charset=utf-8", what
    )
    assert_equal(_header(resp, "content-length"), String(body.byte_length()), what)


def _assert_forbidden(resp: HttpResponse, what: String) raises:
    _assert_refusal(resp, 403, "forbidden\n", what)
    assert_equal(_header(resp, "www-authenticate"), "<absent>", what)
    assert_equal(_header(resp, "retry-after"), "<absent>", what)


def test_unrouted_path_is_forbidden_and_reaches_nothing() raises:
    var rt = RT(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    ref reactor = rt.reactor()
    var gate = _gate(MODE_ALLOW)
    var ctx = _ctx("alice")
    var req = _req(HttpMethod.get(), "/admin")
    var resp = gate.dispatch_with_ctx[RT](reactor, req, ctx)
    _assert_forbidden(resp, "an unrouted path")
    # A non-canonical spelling of a governed path is unrouted too.
    var req2 = _req(HttpMethod.get(), "/repos//acme")
    _assert_forbidden(
        gate.dispatch_with_ctx[RT](reactor, req2, ctx), "a `//` path"
    )
    assert_equal(gate.inner().reached, 0, "the inner dispatcher never ran")
    assert_equal(gate.authz().calls, 0, "the port was never asked")
    _ = gate^
    _ = rt^


def test_refused_row_answers_like_an_unrouted_one() raises:
    var rt = RT(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    ref reactor = rt.reactor()
    var gate = _gate(MODE_ALLOW)
    var ctx = _ctx("alice")
    var req = _req(HttpMethod.delete(), "/repos/acme")
    _assert_forbidden(
        gate.dispatch_with_ctx[RT](reactor, req, ctx), "a refused row"
    )
    assert_equal(gate.inner().reached, 0)
    assert_equal(gate.authz().calls, 0)
    _ = gate^
    _ = rt^


def test_anonymous_unrouted_or_refused_is_403_not_401() raises:
    # The not-governed check comes before authentication: an anonymous
    # request to an undeclared or refused path gets the 403, never a 401
    # challenge.
    var rt = RT(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    ref reactor = rt.reactor()
    var gate = _gate(MODE_ALLOW)
    var anon = _anonymous()
    var req = _req(HttpMethod.get(), "/admin")
    _assert_forbidden(
        gate.dispatch_with_ctx[RT](reactor, req, anon), "anonymous, unrouted"
    )
    var req2 = _req(HttpMethod.delete(), "/repos/acme")
    _assert_forbidden(
        gate.dispatch_with_ctx[RT](reactor, req2, anon), "anonymous, refused"
    )
    assert_equal(gate.inner().reached, 0, "the inner dispatcher never ran")
    assert_equal(gate.authz().calls, 0, "the port was never asked")
    _ = gate^
    _ = rt^


def test_public_route_runs_without_identity() raises:
    var rt = RT(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    ref reactor = rt.reactor()
    var gate = _gate(MODE_DENY)
    # Anonymous: served.
    var anon = _anonymous()
    var req = _req(HttpMethod.get(), "/health")
    var resp = gate.dispatch_with_ctx[RT](reactor, req, anon)
    assert_equal(Int(resp.status), 200)
    assert_equal(_body(resp), "served")
    # Authenticated, with forged gate attributes: served without either.
    var ctx = _ctx("alice")
    var req2 = _req(HttpMethod.get(), "/health")
    var resp2 = gate.dispatch_with_ctx[RT](reactor, req2, ctx)
    assert_equal(Int(resp2.status), 200)
    assert_equal(gate.inner().reached, 2)
    assert_false(gate.inner().had_principal, "no principal on a public route")
    assert_equal(gate.inner().attr_action, "<unset>")
    assert_equal(gate.inner().attr_kind, "<unset>")
    assert_equal(gate.inner().attr_id, "<unset>")
    assert_equal(gate.inner().attr_other, "t-1", "other attributes are kept")
    assert_equal(gate.authz().calls, 0, "a public route asks nobody")
    _ = gate^
    _ = rt^


def test_governed_route_without_identity_is_401() raises:
    var rt = RT(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    ref reactor = rt.reactor()
    var gate = _gate(MODE_ALLOW)
    var anon = _anonymous()
    var req = _req(HttpMethod.get(), "/repos/acme")
    var resp = gate.dispatch_with_ctx[RT](reactor, req, anon)
    _assert_refusal(resp, 401, "unauthorized\n", "no principal")
    assert_equal(_header(resp, "www-authenticate"), "Bearer")
    var empty = _ctx("")
    var req2 = _req(HttpMethod.get(), "/repos/acme")
    var resp2 = gate.dispatch_with_ctx[RT](reactor, req2, empty)
    _assert_refusal(resp2, 401, "unauthorized\n", "an empty subject")
    assert_equal(_header(resp2, "www-authenticate"), "Bearer")
    assert_equal(gate.inner().reached, 0)
    assert_equal(gate.authz().calls, 0)
    _ = gate^
    _ = rt^


def test_allowed_request_reaches_inner_with_what_was_authorized() raises:
    var rt = RT(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    ref reactor = rt.reactor()
    var gate = _gate(MODE_ALLOW)
    var ctx = _ctx("alice")
    var req = _req(HttpMethod.get(), "/repos/acme")
    var resp = gate.dispatch_with_ctx[RT](reactor, req, ctx)
    assert_equal(Int(resp.status), 200)
    assert_equal(_body(resp), "served")
    assert_equal(gate.authz().calls, 1)
    assert_equal(gate.authz().subject, "alice")
    assert_equal(gate.authz().action, "read")
    assert_equal(gate.authz().kind, "repo")
    assert_equal(gate.authz().id, "acme")
    assert_equal(gate.inner().reached, 1)
    assert_true(gate.inner().had_principal)
    assert_equal(gate.inner().attr_action, "read")
    assert_equal(gate.inner().attr_kind, "repo")
    assert_equal(gate.inner().attr_id, "acme")
    assert_equal(gate.inner().attr_other, "t-1")
    # A kind-wide row asks about the kind with an empty id.
    var req2 = _req(HttpMethod.post(), "/repos")
    var resp2 = gate.dispatch_with_ctx[RT](reactor, req2, ctx)
    assert_equal(Int(resp2.status), 200)
    assert_equal(gate.authz().action, "write")
    assert_equal(gate.authz().kind, "repo")
    assert_equal(gate.authz().id, "")
    assert_equal(gate.inner().attr_id, "")
    # The query string is not an input to routing or to the decision.
    var req3 = _req(HttpMethod.get(), "/repos/acme")
    req3.query_string = String("repo=other")
    _ = gate.dispatch_with_ctx[RT](reactor, req3, ctx)
    assert_equal(gate.authz().id, "acme")
    # A one-byte subject is a subject: the shortest one there is.
    var one = _ctx("a")
    var req4 = _req(HttpMethod.get(), "/repos/acme")
    var resp4 = gate.dispatch_with_ctx[RT](reactor, req4, one)
    assert_equal(Int(resp4.status), 200, "a one-byte subject")
    assert_equal(gate.authz().subject, "a")
    assert_equal(gate.authz().calls, 4)
    assert_equal(gate.inner().reached, 4)
    _ = gate^
    _ = rt^


def test_denied_request_is_forbidden() raises:
    var rt = RT(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    ref reactor = rt.reactor()
    var gate = _gate(MODE_DENY)
    var ctx = _ctx("bob")
    var req = _req(HttpMethod.get(), "/repos/acme")
    _assert_forbidden(gate.dispatch_with_ctx[RT](reactor, req, ctx), "a denial")
    assert_equal(gate.authz().calls, 1)
    assert_equal(gate.authz().subject, "bob")
    assert_equal(gate.inner().reached, 0)
    _ = gate^
    _ = rt^


def test_unavailable_decision_is_503() raises:
    var rt = RT(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    ref reactor = rt.reactor()
    var gate = _gate(MODE_RAISE)
    var ctx = _ctx("alice")
    var req = _req(HttpMethod.get(), "/repos/acme")
    var resp = gate.dispatch_with_ctx[RT](reactor, req, ctx)
    _assert_refusal(resp, 503, "authorization unavailable\n", "a raise")
    assert_equal(_header(resp, "retry-after"), "1")
    assert_equal(_header(resp, "www-authenticate"), "<absent>")
    assert_equal(gate.authz().calls, 1)
    assert_equal(gate.inner().reached, 0)
    _ = gate^
    _ = rt^


def test_dispatch_without_chain_is_anonymous() raises:
    var rt = RT(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    ref reactor = rt.reactor()
    var gate = _gate(MODE_ALLOW)
    var resp = gate.dispatch[RT](reactor, _req(HttpMethod.get(), "/repos/acme"))
    _assert_refusal(resp, 401, "unauthorized\n", "dispatch, governed")
    var resp2 = gate.dispatch[RT](reactor, _req(HttpMethod.get(), "/health"))
    assert_equal(Int(resp2.status), 200)
    assert_equal(gate.authz().calls, 0)
    assert_equal(gate.inner().reached, 1)
    var inner = gate^.into_inner()
    assert_equal(inner.reached, 1)
    _ = rt^


def main() raises:
    test_unrouted_path_is_forbidden_and_reaches_nothing()
    test_refused_row_answers_like_an_unrouted_one()
    test_anonymous_unrouted_or_refused_is_403_not_401()
    test_public_route_runs_without_identity()
    test_governed_route_without_identity_is_401()
    test_allowed_request_reaches_inner_with_what_was_authorized()
    test_denied_request_is_forbidden()
    test_unavailable_decision_is_503()
    test_dispatch_without_chain_is_anonymous()
    print("PASS komira_resource_gate test_gate")
