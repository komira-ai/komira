# komira_github

A GitHub App's client for a small, fixed subset of the GitHub REST API, and
webhook delivery verification. It talks to GitHub as the App (an RS256 JWT
signed with the App's private key through komira_crypto) and as each of its
installations (installation access tokens, minted through the App JWT and
cached), over komira_http_client.

The subset is data (`github_routes()`), and every request is matched against
it before a credential is minted or a byte is sent:

| credential | routes |
|---|---|
| App JWT | `GET /app`, `GET /app/installations/{id}`, `GET /repos/{owner}/{repo}/installation`, `POST /app/installations/{id}/access_tokens` |
| installation token | installation repositories; a repository; workflow runs, run attempts, jobs (of a run and of an attempt), a job, run artifacts, an artifact; a collaborator's permission; check runs (create, update); a file's contents |

Nothing else can be sent: no write to Actions (no `workflow_dispatch`, no
re-run), no write to contents, no environments, no administration. A request
outside the subset raises `GitHubError[NOT_ALLOWED]` with nothing sent.

What the client does for you:

- **The App JWT**: `iat` 60 s in the past, `exp` 540 s ahead (GitHub allows
  at most 10 minutes), re-minted when 60 s or fewer remain, and checked
  against GitHub's window before every send.
- **Installation tokens**: cached per installation and per scope, and
  replaced once 300 s or less of the hour remain. `repo_contents_read_token`
  asks for a token limited to ONE repository and `contents: read`.
- **Pagination**: `list_all` reads a list route page by page until a page's
  `Link` header has no `rel="next"`. It takes only the page number from the
  link and asks the same route again, so a link never moves the token to
  another URL.
- **Rate limits**: a primary limit (`x-ratelimit-remaining: 0`) holds that
  credential until `x-ratelimit-reset`; a secondary limit holds the whole
  client for `retry-after`, or 60 s doubling while it repeats (at most an
  hour). Nothing is retried: a call made while a limit holds raises
  `GitHubError[RATE_LIMITED]` without sending.
- **Webhooks**: `verify_webhook_delivery` requires exactly one
  `X-Hub-Signature-256` of 64 lowercase hex digits, refuses the SHA-1
  `X-Hub-Signature` alone, and compares in constant time.

Errors are `GitHubError[<KIND>]: ...` (`github_error_kind` reads the kind)
and never quote a response body, a token or the key. `komira_github_fake`
answers the same subset in memory for tests.

## Examples

Verifying a webhook delivery, with GitHub's own documented example:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_github import GitHubHeader, github_error_kind, verify_webhook_delivery

var secret = String("It's a Secret to Everybody")
var body = String("Hello, World!")
var headers = List[GitHubHeader]()
headers.append(GitHubHeader(String("X-GitHub-Event"), String("ping")))
headers.append(GitHubHeader(
    String("X-Hub-Signature-256"),
    String("sha256=757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17"),
))
verify_webhook_delivery(secret.as_bytes(), body.as_bytes(), headers)

var forged = String("Hello, World?")
var why = String("")
try:
    verify_webhook_delivery(secret.as_bytes(), forged.as_bytes(), headers)
except e:
    why = String(e)
assert_equal(github_error_kind(why), "WEBHOOK")
```

Building requests: each builder makes a request of the subset, and anything
else matches no row:

```mojo
from komira_github import create_repo_contents_read_token, get_contents, github_routes, match_route

var req = get_contents("octo-org", "app", ".github/release machine.yml", "v1.2")
assert_equal(req.target(), "/repos/octo-org/app/contents/.github/release%20machine.yml?ref=v1.2")
assert_equal(github_routes()[match_route(req.method, req.path)].name, "repos/get-content")

var token_req = create_repo_contents_read_token(42, 7)
assert_equal(
    String(unsafe_from_utf8=Span(token_req.body)),
    '{"repository_ids":[7],"permissions":{"contents":"read"}}',
)

assert_equal(match_route("PUT", "/repos/octo-org/app/environments/prod"), -1)
assert_equal(match_route("POST", "/repos/octo-org/app/actions/workflows/7/dispatches"), -1)
```

Reading a page's `Link` header and a rate-limited answer:

```mojo
from komira_github import GitHubHeader, RATE_LIMIT_SECONDARY, classify_rate_limit, link_next_page

var link = String(
    '<https://api.github.com/repositories/1/issues?page=2>; rel="next", '
    + '<https://api.github.com/repositories/1/issues?page=5>; rel="last"'
)
assert_equal(link_next_page(link), 2)
assert_equal(link_next_page(String('<https://api.github.com/x?page=4>; rel="prev"')), 0)

var limited = List[GitHubHeader]()
limited.append(GitHubHeader(String("retry-after"), String("30")))
var verdict = classify_rate_limit(403, limited, List[UInt8](), 1_790_856_000, 0)
assert_equal(verdict.kind, RATE_LIMIT_SECONDARY)
assert_equal(verdict.resume_at, 1_790_856_030)
```

The client itself, in production, is `GitHubAppClient` over
`HttpsGitHubTransport` with `GitHubEndpoint.public()` (or `.enterprise(host,
port)` for a GitHub Enterprise Server) and `SystemUnixClock`; its key comes
from `AppCredentials.from_pem(app_id_or_client_id, pem)`, where the PEM is a
PKCS#8 `PRIVATE KEY` (convert GitHub's PKCS#1 download with `openssl pkcs8
-topk8 -nocrypt`).

```text
var client = GitHubAppClient[HttpsGitHubTransport[TlsConnector], SystemUnixClock](
    HttpsGitHubTransport[TlsConnector](http, GitHubEndpoint.public()),
    AppCredentials.from_pem(String("Iv23li..."), pem),
    SystemUnixClock(),
)
var runs = client.list_all(installation_id, list_workflow_runs("octo-org", "app", head_sha))
```
