"""`komira_gcp_core` — the one hand-written core of komira's Google Cloud SDK.

The generated `komira_gcp_<service>` clients import this package's ROOT and
nothing else of it (proto-codegen `emit_rest.rs`); this package never imports
a generated module.

ONE transport seam, and it is not in this package: the generated clients are
parameterized on komira_http's `Connector` (`emit_rest.rs` `rest_imports`:
`<Svc>Client[C: Connector, T: GcpTokenSource]`). They build the URL and the
`Bearer` header themselves and send through komira_http's `HttpClient`. From
this package they take `GcpTokenSource` and `gcp_status_error`, and the pure
pieces a caller composes into its own loop: `GcpRetryClassifier` (for a
komira_retry `RetryLoop`), `PageCursor`, `next_page_token` and `with_page_token`. This package defines
no request/response type and no send loop.

This is part P18a-1. Still to come:
  - P18a-2 (pure, no http): service-account key file parse, the RS256 JWT
    assertion, the authorized_user refresh form body, the metadata/oauth
    token-response parse, and the STS token exchange + generateAccessToken
    request/response codecs.
  - P18b (over the `Connector`, depends on P18a-2): the token sources
    (metadata server, service-account JWT, authorized_user, workload
    identity federation) and the send/decide/sleep retry loop.
  - P21b: the paging loop, in the generated logging client.

Modules (only GCP-specific code lives here; JSON and its UTF-8 validation
come from komira_json, and retry/backoff and the clock seam from
komira_retry):
  - token.mojo      : `GcpTokenSource` (the generated clients' contract),
                      `AccessToken`, `AccessTokenFetcher`,
                      `CachingTokenSource` (on komira_retry's
                      `MonotonicClock` seam), `StaticTokenSource`.
  - status.mojo     : the `google.rpc.Status` error envelope:
                      `parse_gcp_status` / `GcpStatusError` and
                      `gcp_status_error` (the generated clients' contract).
                      Never echoes a body byte.
  - pagination.mojo : `pageToken` / `nextPageToken` paging (AIP-158):
                      `PageCursor`, `next_page_token`, `with_page_token`.
  - retry.mojo      : `GcpRetryClassifier` (AIP-194 retryable codes, with
                      google.rpc.RetryInfo as the server delay) and
                      `gcp_retry_policy` (AIP-4221 backoff); the policy,
                      backoff and loop themselves are komira_retry's.

Nothing in this package reads the environment or opens a socket.
"""
from .token import (
    DEFAULT_REFRESH_BEFORE_MS,
    AccessToken,
    AccessTokenFetcher,
    CachingTokenSource,
    GcpTokenSource,
    StaticTokenSource,
)
from .status import (
    CODE_OK,
    CODE_CANCELLED,
    CODE_UNKNOWN,
    CODE_INVALID_ARGUMENT,
    CODE_DEADLINE_EXCEEDED,
    CODE_NOT_FOUND,
    CODE_ALREADY_EXISTS,
    CODE_PERMISSION_DENIED,
    CODE_RESOURCE_EXHAUSTED,
    CODE_FAILED_PRECONDITION,
    CODE_ABORTED,
    CODE_OUT_OF_RANGE,
    CODE_UNIMPLEMENTED,
    CODE_INTERNAL,
    CODE_UNAVAILABLE,
    CODE_DATA_LOSS,
    CODE_UNAUTHENTICATED,
    ENVELOPE_PRESENT,
    ENVELOPE_ABSENT,
    ENVELOPE_MALFORMED,
    GcpStatusError,
    code_from_http_status,
    code_from_name,
    code_name,
    gcp_status_error,
    parse_gcp_status,
    duration_to_ms,
    RETRY_INFO_TYPE,
)
from .pagination import (
    DEFAULT_MAX_PAGES,
    PageCursor,
    next_page_token,
    with_page_token,
)
from .retry import GcpRetryClassifier, gcp_retry_policy
