# =============================================================================
# komira_github_fake/fake.mojo -- `FakeGitHub`: GitHub's REST subset, in
#   memory, as a komira_github `GitHubTransport`.
# =============================================================================
#
# A fake, not a mock: it holds repositories, installations, tokens, runs,
# jobs, artifacts, check runs and files (state.mojo), checks every
# credential the way GitHub does, and answers each route of komira_github's
# subset from that state. A client under test is the real
# `GitHubAppClient` with this as its transport.
#
# For every request, in order:
#   1. it is recorded (`requests`, `request_count`, `count_route`);
#   2. an armed answer (`arm`, `arm_secondary_limit`, `arm_primary_limit`)
#      is returned first, whatever the request;
#   3. a request outside the subset is 404 and counted in
#      `unrouted_requests` (a client that sent one is broken);
#   4. the credential: `Authorization: Bearer <App JWT>` for an App route
#      (app_auth.mojo; 401 when refused), `Bearer <installation token>` for
#      an installation route (401 when unknown or expired, 403 when its
#      installation is suspended or it lacks the route's permission);
#   5. the route's handler (handlers.mojo, repo_handlers.mojo).
#
# The fake's clock is `now`, set by the test (`set_now`, `advance`); it is
# not the client's clock, so a test can make them disagree.
# =============================================================================

from komira_github import (
    AUTH_APP,
    GitHubHttpRequest,
    GitHubResponse,
    GitHubRoute,
    GitHubTransport,
    github_routes,
    match_route,
    webhook_signature_256,
    GitHubHeader,
)

from .app_auth import FakeAppPublicKey, check_app_jwt
from .handlers import handle_app_route, template_params
from .model import grants
from .render import error_response
from .repo_handlers import handle_installation_route
from .state import FakeState


comptime FAKE_LINK_BASE: String = "https://api.github.com"


def default_app_permissions() -> List[String]:
    """What a release App asks for: read metadata, contents and Actions,
    write check runs. No Actions write and no contents write."""
    var p = List[String]()
    p.append(String("metadata:read"))
    p.append(String("contents:read"))
    p.append(String("actions:read"))
    p.append(String("checks:write"))
    return p^


struct FakeGitHub(GitHubTransport, Movable, Deinitable):
    """GitHub in memory (module header)."""

    var state: FakeState
    var issuer: String
    var app_key: FakeAppPublicKey
    var link_base: String
    var requests: List[GitHubHttpRequest]
    var unrouted_requests: Int
    var _armed: List[GitHubResponse]
    var _routes: List[GitHubRoute]

    def __init__(
        out self,
        var issuer: String,
        var app_key: FakeAppPublicKey,
        now: Int64,
        var app_permissions: List[String] = default_app_permissions(),
    ):
        self.state = FakeState(now, app_permissions^)
        self.issuer = issuer^
        self.app_key = app_key^
        self.link_base = String(FAKE_LINK_BASE)
        self.requests = List[GitHubHttpRequest]()
        self.unrouted_requests = 0
        self._armed = List[GitHubResponse]()
        self._routes = github_routes()

    # --- clock and scripted answers -------------------------------------------

    def set_now(mut self, now: Int64):
        self.state.now = now

    def advance(mut self, seconds: Int64):
        self.state.now += seconds

    def arm(mut self, var resp: GitHubResponse):
        """Answer the next request with `resp`, whatever it is."""
        self._armed.append(resp^)

    def arm_secondary_limit(mut self, retry_after_s: Int64 = -1):
        """The next request gets GitHub's secondary-limit 403: the message,
        and `retry-after` when `retry_after_s` is not negative."""
        var resp = error_response(
            403,
            String(
                "You have exceeded a secondary rate limit. Please wait a few minutes before you try again."
            ),
        )
        if retry_after_s >= 0:
            resp.add_header(String("retry-after"), String(retry_after_s))
        self._armed.append(resp^)

    def arm_primary_limit(mut self, reset_at: Int64):
        """The next request gets GitHub's primary-limit 403
        (`x-ratelimit-remaining: 0`, `x-ratelimit-reset`)."""
        var resp = error_response(403, String("API rate limit exceeded for installation."))
        resp.add_header(String("x-ratelimit-limit"), String("5000"))
        resp.add_header(String("x-ratelimit-remaining"), String("0"))
        resp.add_header(String("x-ratelimit-reset"), String(reset_at))
        self._armed.append(resp^)

    # --- what was asked ---------------------------------------------------------

    def request_count(self) -> Int:
        return len(self.requests)

    def count_route(self, name: String) -> Int:
        """How many recorded requests matched the route named `name`."""
        var n = 0
        for i in range(len(self.requests)):
            var path = self.requests[i].target
            var q = path.find("?")
            if q >= 0:
                path = String(self.requests[i].target[byte=0:q])
            var idx = match_route(self.requests[i].method, path)
            if idx >= 0 and self._routes[idx].name == name:
                n += 1
        return n

    # --- the transport ------------------------------------------------------------

    def send(mut self, req: GitHubHttpRequest) raises -> GitHubResponse:
        self.requests.append(req.copy())
        if len(self._armed) > 0:
            return self._armed.pop(0)
        var path = req.target
        var query = String("")
        var q = req.target.find("?")
        if q >= 0:
            path = String(req.target[byte=0:q])
            query = String(req.target[byte = q + 1 : req.target.byte_length()])
        var idx = match_route(req.method, path)
        if idx < 0:
            self.unrouted_requests += 1
            return error_response(404, String("Not Found"))
        var route = self._routes[idx]
        var params = template_params(route.template, path)
        var bearer = String("")
        var auth = req.header(String("Authorization"))
        if auth and auth.value().startswith("Bearer "):
            bearer = String(auth.value()[byte = 7 : auth.value().byte_length()])
        if route.auth == AUTH_APP:
            try:
                check_app_jwt(bearer, self.issuer, self.app_key, self.state.now)
            except e:
                return error_response(401, String(e))
            return handle_app_route(self.state, route.name, params, req.body, self.issuer)
        var ti = self.state.token_index(bearer)
        if ti < 0:
            return error_response(401, String("Bad credentials"))
        var token = self.state.tokens[ti].copy()
        if token.expires_at <= self.state.now:
            return error_response(401, String("Bad credentials"))
        var ii = self.state.installation_index(token.installation_id)
        if ii < 0:
            return error_response(401, String("Bad credentials"))
        if self.state.installations[ii].suspended:
            return error_response(403, String("This installation has been suspended"))
        if not grants(token.permissions, route.permission):
            return error_response(403, String("Resource not accessible by integration"))
        return handle_installation_route(
            self.state, route.name, path, params, query, req.body, token, self.link_base
        )


def signed_delivery_headers(
    secret: Span[UInt8, _], body: Span[UInt8, _], event: String, delivery_id: String
) -> List[GitHubHeader]:
    """The headers GitHub sends with a webhook delivery of `body`:
    `X-GitHub-Event`, `X-GitHub-Delivery`, `Content-Type` and
    `X-Hub-Signature-256` signed with `secret`."""
    var h = List[GitHubHeader]()
    h.append(GitHubHeader(String("X-GitHub-Event"), event))
    h.append(GitHubHeader(String("X-GitHub-Delivery"), delivery_id))
    h.append(GitHubHeader(String("Content-Type"), String("application/json")))
    h.append(GitHubHeader(String("X-Hub-Signature-256"), webhook_signature_256(secret, body)))
    return h^
