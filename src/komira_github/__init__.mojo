"""`komira_github`: a GitHub App's client for a small, fixed subset of the
GitHub REST API, and webhook delivery verification.

Modules:
  - app_jwt.mojo     the App JWT (RS256 over komira_crypto): `iat` 60 s back,
                     `exp` 540 s ahead, GitHub's 10-minute window checked
                     before every send.
  - token_cache.mojo installation access tokens, cached per installation and
                     scope, replaced 300 s before they expire.
  - route.mojo       the REST subset as data and the matcher every request
                     passes; anything else is refused before it is sent.
  - request.mojo     one builder per route, the one-repository
                     `contents: read` token body, check-run bodies.
  - link.mojo        `Link` header pagination (only the page number is used).
  - rate_limit.mojo  primary and secondary limits, and the latch that never
                     lets a limited client send early.
  - webhook.mojo     `X-Hub-Signature-256` verification, constant time.
  - transport.mojo   the transport seam, and the komira_http_client one.
  - client.mojo      `GitHubAppClient`.
  - clock.mojo       the wall-clock seam.
  - error.mojo       `GitHubError[<KIND>]` errors.

komira_github_fake answers the same subset in memory for tests.

No public function takes or returns a pointer.
"""

from .app_jwt import (
    APP_JWT_BACKDATE_S,
    APP_JWT_HEADER_JSON,
    APP_JWT_MAX_SPAN_S,
    APP_JWT_REMINT_MARGIN_S,
    APP_JWT_TTL_S,
    AppCredentials,
    AppJwt,
    app_jwt_needs_remint,
    app_jwt_payload_json,
    check_app_jwt_window,
    mint_app_jwt,
)
from .client import (
    DEFAULT_MAX_PAGES,
    GitHubAppClient,
    decode_contents_file,
    status_error,
)
from .clock import ManualUnixClock, SystemUnixClock, UnixClock
from .error import (
    KIND_AUTH,
    KIND_BAD_INPUT,
    KIND_BAD_RESPONSE,
    KIND_HTTP_STATUS,
    KIND_NOT_ALLOWED,
    KIND_RATE_LIMITED,
    KIND_WEBHOOK,
    github_error,
    github_error_kind,
)
from .header import GitHubHeader, ascii_lower, header_count, header_value
from .link import LinkEntry, link_next_page, parse_link_header, query_param
from .rate_limit import (
    RATE_LIMIT_NONE,
    RATE_LIMIT_PRIMARY,
    RATE_LIMIT_SECONDARY,
    RateLimitLatch,
    RateLimitVerdict,
    SECONDARY_MAX_WAIT_S,
    SECONDARY_MIN_WAIT_S,
    classify_rate_limit,
    secondary_backoff_s,
)
from .request import (
    CheckRunFields,
    DEFAULT_PER_PAGE,
    GitHubRequest,
    check_run_body,
    create_check_run,
    create_installation_token,
    create_repo_contents_read_token,
    encode_contents_path,
    get_artifact,
    get_authenticated_app,
    get_collaborator_permission,
    get_contents,
    get_installation,
    get_job,
    get_repo_installation,
    get_repository,
    get_workflow_run,
    get_workflow_run_attempt,
    is_check_conclusion,
    is_check_status,
    list_installation_repositories,
    list_jobs_for_workflow_run,
    list_jobs_for_workflow_run_attempt,
    list_workflow_run_artifacts,
    list_workflow_runs,
    percent_encode,
    repo_contents_read_token_body,
    update_check_run,
)
from .route import (
    AUTH_APP,
    AUTH_INSTALLATION,
    GitHubRoute,
    check_query,
    github_routes,
    is_id_segment,
    is_name_segment,
    is_path_segment,
    match_route,
    match_template,
    path_segments,
    route_index,
)
from .token_cache import (
    INSTALLATION_TOKEN_REFRESH_MARGIN_S,
    InstallationToken,
    InstallationTokenCache,
    read_installation_token,
    token_is_fresh,
)
from .transport import (
    GITHUB_ACCEPT,
    GITHUB_API_VERSION,
    GITHUB_PUBLIC_HOST,
    GITHUB_USER_AGENT,
    GitHubEndpoint,
    GitHubHttpRequest,
    GitHubResponse,
    GitHubTransport,
    HttpsGitHubTransport,
)
from .webhook import (
    WEBHOOK_SIGNATURE_256_HEADER,
    WEBHOOK_SIGNATURE_PREFIX,
    WEBHOOK_SIGNATURE_SHA1_HEADER,
    verify_webhook_delivery,
    verify_webhook_signature,
    webhook_digest_diff,
    webhook_signature_256,
)
