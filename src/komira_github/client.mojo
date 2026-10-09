# =============================================================================
# komira_github/client.mojo -- `GitHubAppClient`: a GitHub App talking to the
#   REST subset as itself and as its installations.
# =============================================================================
#
# ORDER of every send, each step able to stop it before anything is sent:
#   1. the request must match a row of route.mojo's subset with a well-formed
#      query, and the row must take the credential being used (an App route
#      with the App JWT, an installation route with an installation token):
#      else `GitHubError[NOT_ALLOWED]`;
#   2. the rate-limit latch must not be holding the credential's quota or
#      the whole client: else `GitHubError[RATE_LIMITED]`;
#   3. the credential: the App JWT, re-minted when 60 s or fewer of it
#      remain and checked against GitHub's window (app_jwt.mojo); or an
#      installation token from the cache, minted through the App JWT when
#      there is no fresh one (token_cache.mojo);
#   4. the transport sends it, with `Authorization: Bearer <credential>`,
#      `Accept: application/vnd.github+json`, `X-GitHub-Api-Version:
#      2022-11-28` and `User-Agent: komira-github` (and `Content-Type:
#      application/json` when there is a body);
#   5. the answer is read for rate limits first: a limited answer is
#      recorded in the latch and raised as `GitHubError[RATE_LIMITED]`,
#      naming the instant sending resumes. Nothing is retried, here or in a
#      page walk. A 401 drops the credential that was refused (the cached
#      JWT, or every cached token of the installation) and raises
#      `GitHubError[AUTH]`.
# Any other status is returned to the caller from `app_send`, `send` and
# `send_with_token`; `list_all`, `read_file` and the token mints raise
# `GitHubError[HTTP_STATUS]` for a non-2xx answer instead. No error quotes a
# body, a token or the key.
#
# Pages. `list_all` walks a list route: it sends the request, collects the
# route's items member from each page, and asks the same route again with
# `page=<n>` while the answer's Link header has a `rel="next"` (link.mojo),
# so the walk ends only on a page with no next link, i.e. after the last
# page has been read. A next page that does not advance, or a walk past
# `max_pages` (default 100), raises rather than loops.
# =============================================================================

from komira_encoding import base64_decode
from komira_json import JSON_ARRAY, JSON_STRING, JsonValue

from .app_jwt import (
    AppCredentials,
    AppJwt,
    app_jwt_needs_remint,
    check_app_jwt_window,
    mint_app_jwt,
)
from .clock import UnixClock
from .error import (
    KIND_AUTH,
    KIND_BAD_INPUT,
    KIND_BAD_RESPONSE,
    KIND_HTTP_STATUS,
    KIND_NOT_ALLOWED,
    KIND_RATE_LIMITED,
    github_error,
)
from .link import link_next_page, query_param
from .rate_limit import (
    RATE_LIMIT_NONE,
    RATE_LIMIT_PRIMARY,
    RateLimitLatch,
    classify_rate_limit,
)
from .request import (
    GitHubRequest,
    create_installation_token,
    create_repo_contents_read_token,
    get_contents,
)
from .route import AUTH_APP, AUTH_INSTALLATION, GitHubRoute, check_query, github_routes, match_route
from .token_cache import InstallationToken, InstallationTokenCache, read_installation_token, token_is_fresh
from .transport import (
    GITHUB_ACCEPT,
    GITHUB_API_VERSION,
    GITHUB_USER_AGENT,
    GitHubHttpRequest,
    GitHubResponse,
    GitHubTransport,
)


comptime DEFAULT_MAX_PAGES: Int = 100
comptime APP_LATCH_KEY: String = "app"


def _installation_key(installation_id: Int64) -> String:
    return String("installation:") + String(installation_id)


def status_error(resp: GitHubResponse, route_name: String) -> Error:
    """The error for a non-2xx answer: AUTH for 401, else HTTP_STATUS, each
    naming the status and the route and nothing of the body."""
    var kind = String(KIND_HTTP_STATUS)
    if resp.status == 401:
        kind = String(KIND_AUTH)
    return github_error(
        kind, String("GitHub answered ") + String(resp.status) + String(" to ") + route_name
    )


def decode_contents_file(resp: GitHubResponse) raises -> List[UInt8]:
    """The bytes of a `repos/get-content` answer for one file: `type` must
    be `file` and `encoding` `base64`; the content's line breaks (GitHub
    wraps it) are dropped before decoding."""
    if not resp.ok():
        raise status_error(resp, String("repos/get-content"))
    var doc = resp.json()
    var kind = String("")
    var encoding = String("")
    var content = String("")
    try:
        var t = doc.get(String("type"))
        var e = doc.get(String("encoding"))
        var c = doc.get(String("content"))
        if t.kind_tag() == JSON_STRING:
            kind = t.as_string()
        if e.kind_tag() == JSON_STRING:
            encoding = e.as_string()
        if c.kind_tag() == JSON_STRING:
            content = c.as_string()
    except:
        raise github_error(KIND_BAD_RESPONSE, "the contents answer has no type, encoding and content")
    if kind != "file":
        raise github_error(KIND_BAD_RESPONSE, "the contents answer is not a file")
    if encoding != "base64":
        raise github_error(KIND_BAD_RESPONSE, "the contents answer is not base64 (a file over 1 MB?)")
    var b = content.as_bytes()
    var packed = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        if b[i] != UInt8(ord("\n")) and b[i] != UInt8(ord("\r")):
            packed.append(b[i])
    try:
        return base64_decode(Span[UInt8, origin_of(packed)](packed))
    except:
        raise github_error(KIND_BAD_RESPONSE, "the contents answer's content is not base64")


struct GitHubAppClient[T: GitHubTransport, K: UnixClock](Movable, Deinitable):
    """A GitHub App's client (module header): `T` sends, `K` is the wall
    clock every expiry and limit is compared against."""

    var _transport: Self.T
    var _clock: Self.K
    var _creds: AppCredentials
    var _jwt: Optional[AppJwt]
    var _tokens: InstallationTokenCache
    var _latch: RateLimitLatch
    var _routes: List[GitHubRoute]
    var max_pages: Int

    def __init__(out self, var transport: Self.T, var creds: AppCredentials, var clock: Self.K):
        self._transport = transport^
        self._clock = clock^
        self._creds = creds^
        self._jwt = None
        self._tokens = InstallationTokenCache()
        self._latch = RateLimitLatch()
        self._routes = github_routes()
        self.max_pages = DEFAULT_MAX_PAGES

    def transport(mut self) -> ref [self._transport] Self.T:
        """The transport (a test reads its fake through this)."""
        return self._transport

    def clock(mut self) -> ref [self._clock] Self.K:
        """The clock (a test moves its manual clock through this)."""
        return self._clock

    def latch(self) -> ref [self._latch] RateLimitLatch:
        return self._latch

    def _now(mut self) -> Int64:
        return self._clock.now_unix_seconds()

    # --- step 1 ---------------------------------------------------------------

    def _route_for(self, req: GitHubRequest, auth: Int) raises -> Int:
        var idx = match_route(req.method, req.path)
        if idx < 0:
            raise github_error(
                KIND_NOT_ALLOWED,
                req.method + String(" ") + req.path + String(" is not in the REST subset; nothing was sent"),
            )
        if not check_query(req.query):
            raise github_error(KIND_NOT_ALLOWED, "the query is not key=value pairs of escaped bytes")
        if self._routes[idx].auth != auth:
            if auth == AUTH_APP:
                raise github_error(
                    KIND_NOT_ALLOWED,
                    self._routes[idx].name + String(" takes an installation token, not the App JWT"),
                )
            raise github_error(
                KIND_NOT_ALLOWED, self._routes[idx].name + String(" takes the App JWT, not an installation token")
            )
        return idx

    # --- step 3 (App JWT) -------------------------------------------------------

    def _app_jwt(mut self) raises -> String:
        var now = self._now()
        var remint = True
        if self._jwt:
            remint = app_jwt_needs_remint(self._jwt.value(), now)
        if remint:
            self._jwt = mint_app_jwt(self._creds, now)
        ref jwt = self._jwt.value()
        check_app_jwt_window(jwt.iat, jwt.exp, now)
        return jwt.token

    # --- steps 2, 4, 5 ------------------------------------------------------------

    def _exchange(
        mut self, req: GitHubRequest, bearer: String, key: String, route_name: String
    ) raises -> GitHubResponse:
        var now = self._now()
        self._latch.check(key, now)
        var wire = GitHubHttpRequest(req.method, req.target())
        wire.add_header(String("Accept"), String(GITHUB_ACCEPT))
        wire.add_header(String("Authorization"), String("Bearer ") + bearer)
        wire.add_header(String("User-Agent"), String(GITHUB_USER_AGENT))
        wire.add_header(String("X-GitHub-Api-Version"), String(GITHUB_API_VERSION))
        if len(req.body) > 0:
            wire.add_header(String("Content-Type"), String("application/json"))
            wire.body = req.body.copy()
        var resp = self._transport.send(wire)
        var verdict = classify_rate_limit(
            resp.status, resp.headers, resp.body, now, self._latch.secondary_streak
        )
        self._latch.record(key, verdict)
        if verdict.kind != RATE_LIMIT_NONE:
            var which = String("a secondary rate limit")
            if verdict.kind == RATE_LIMIT_PRIMARY:
                which = String("a primary rate limit")
            raise github_error(
                KIND_RATE_LIMITED,
                String("GitHub answered ")
                + String(resp.status)
                + String(" to ")
                + route_name
                + String(" with ")
                + which
                + String("; not retried; sending resumes at unix ")
                + String(verdict.resume_at),
            )
        return resp^

    # --- the App's own routes ---------------------------------------------------

    def app_send(mut self, req: GitHubRequest) raises -> GitHubResponse:
        """Send an App route with the App JWT. A 401 drops the cached JWT
        and raises; any other answer is returned."""
        var idx = self._route_for(req, AUTH_APP)
        var name = self._routes[idx].name
        var jwt = self._app_jwt()
        var resp = self._exchange(req, jwt, String(APP_LATCH_KEY), name)
        if resp.status == 401:
            self._jwt = None
            raise status_error(resp, name)
        return resp^

    def _mint(mut self, installation_id: Int64, req: GitHubRequest) raises -> InstallationToken:
        var scope = String(unsafe_from_utf8=Span(req.body))
        var now = self._now()
        var cached = self._tokens.get(installation_id, scope, now)
        if cached:
            return cached.value().copy()
        var resp = self.app_send(req)
        if resp.status != 201:
            raise status_error(resp, String("apps/create-installation-access-token"))
        var tok = read_installation_token(resp.body, installation_id, scope^, self._now())
        self._tokens.put(tok)
        return tok^

    def installation_token(mut self, installation_id: Int64) raises -> InstallationToken:
        """A token for the installation's whole grant: the cached one while
        fresh, else a new one."""
        return self._mint(installation_id, create_installation_token(installation_id))

    def repo_contents_read_token(
        mut self, installation_id: Int64, repository_id: Int64
    ) raises -> InstallationToken:
        """A token for ONE repository with `contents: read` only (request.mojo):
        the cached one while fresh, else a new one."""
        return self._mint(
            installation_id, create_repo_contents_read_token(installation_id, repository_id)
        )

    # --- installation routes ----------------------------------------------------

    def _send_as(
        mut self, token: InstallationToken, req: GitHubRequest, route_name: String
    ) raises -> GitHubResponse:
        var resp = self._exchange(
            req, token.token, _installation_key(token.installation_id), route_name
        )
        if resp.status == 401:
            self._tokens.invalidate(token.installation_id)
            raise status_error(resp, route_name)
        return resp^

    def send(mut self, installation_id: Int64, req: GitHubRequest) raises -> GitHubResponse:
        """Send an installation route with the installation's token."""
        var idx = self._route_for(req, AUTH_INSTALLATION)
        var name = self._routes[idx].name
        var token = self.installation_token(installation_id)
        return self._send_as(token, req, name)

    def send_with_token(mut self, token: InstallationToken, req: GitHubRequest) raises -> GitHubResponse:
        """Send an installation route with a token the caller holds (a
        scoped one). Refused without sending when the token is no longer
        fresh (token_cache.mojo's margin)."""
        var idx = self._route_for(req, AUTH_INSTALLATION)
        var name = self._routes[idx].name
        if not token_is_fresh(token.expires_at, self._now()):
            raise github_error(KIND_AUTH, "the installation token is expired or about to expire; nothing was sent")
        return self._send_as(token, req, name)

    def list_all(mut self, installation_id: Int64, req: GitHubRequest) raises -> List[JsonValue]:
        """Every item of a list route, page after page until a page has no
        `rel="next"` link (module header)."""
        var idx = self._route_for(req, AUTH_INSTALLATION)
        var name = self._routes[idx].name
        var items_key = self._routes[idx].items_key
        if items_key.byte_length() == 0:
            raise github_error(KIND_NOT_ALLOWED, name + String(" is not a list route"))
        if query_param(String("?") + req.query, String("page")):
            raise github_error(KIND_BAD_INPUT, "a list_all request must not name a page")
        var out = List[JsonValue]()
        var page = 1
        var pages = 0
        while True:
            var this_req = req.copy()
            if page > 1:
                if this_req.query.byte_length() > 0:
                    this_req.query += "&"
                this_req.query += String("page=") + String(page)
            var resp = self.send(installation_id, this_req)
            if not resp.ok():
                raise status_error(resp, name)
            pages += 1
            var doc = resp.json()
            var items: JsonValue
            try:
                items = doc.get(items_key)
            except:
                raise github_error(KIND_BAD_RESPONSE, name + String(" page has no ") + items_key)
            if items.kind_tag() != JSON_ARRAY:
                raise github_error(KIND_BAD_RESPONSE, name + String(" page's ") + items_key + String(" is not an array"))
            for i in range(items.array_len()):
                out.append(items.element_at(i))
            var link = resp.header(String("link"))
            if not link:
                break
            var next_page = link_next_page(link.value())
            if next_page == 0:
                break
            if next_page <= page:
                raise github_error(KIND_BAD_RESPONSE, "the next page does not come after this one")
            if pages >= self.max_pages:
                raise github_error(
                    KIND_BAD_RESPONSE,
                    name + String(" has more than ") + String(self.max_pages) + String(" pages"),
                )
            page = next_page
        return out^

    def read_file(
        mut self,
        installation_id: Int64,
        owner: String,
        repo: String,
        path: String,
        git_ref: String = String(""),
    ) raises -> List[UInt8]:
        """The bytes of one file at `git_ref` (`repos/get-content`)."""
        var resp = self.send(installation_id, get_contents(owner, repo, path, git_ref))
        return decode_contents_file(resp)
