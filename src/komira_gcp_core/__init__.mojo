"""`komira_gcp_core` — the one hand-written core of komira's Google Cloud SDK.

The generated `komira_gcp_<service>` clients import this package's ROOT and
nothing else of it (proto-codegen `emit_rest.rs`, and `emit.rs` for gRPC);
this package never imports a generated module.

ONE transport seam, and it is not in this package: the generated clients are
parameterized on komira_http's `Connector`. A REST client (`emit_rest.rs`
`rest_imports`: `<Svc>Client[C: Connector, T: GcpTokenSource]`) builds the
URL and the `Bearer` header itself and sends through komira_http's
`HttpClient`; from this package it takes `GcpTokenSource` and
`gcp_status_error`. A gRPC client (`emit.rs`, the same parameters) sends
through komira_grpc's `GrpcClient`, sets the token from its `GcpTokenSource`
as each call's `authorization` metadata, and takes `gcp_grpc_status_error`
for a non-OK gRPC status. Either may be composed with the pure pieces a
caller puts into its own loop: `GcpRetryClassifier` (for a komira_retry
`RetryLoop`), `PageCursor`, `next_page_token` and `with_page_token`. This
package defines no request/response type and no send loop for a generated
client; the only requests it sends are its own token requests
(token_http.mojo), because the OAuth 2.0 token endpoint and the metadata
server have no googleapis proto to generate a client from.

Token sources: `application_default_token_source` resolves Application
Default Credentials in Google's order (adc.mojo) and returns a
`CachingTokenSource` over the fetcher it chose. The fetchers (metadata
server, service-account key, self-signed JWT, authorized_user) send over
komira_http_client through the caller's connectors and `HttpClientConfig`.
Not read here: workload identity federation's `external_account` files,
which the chain refuses by name.

Modules (only GCP-specific code lives here; JSON and its UTF-8 validation
come from komira_json, and retry/backoff and the clock seam from
komira_retry):
  - token.mojo      : `GcpTokenSource` (the generated clients' contract),
                      `AccessToken`, `AccessTokenFetcher`,
                      `CachingTokenSource` (on komira_retry's
                      `MonotonicClock` seam), `StaticTokenSource`.
  - status.mojo     : the `google.rpc.Status` error envelope:
                      `parse_gcp_status` / `GcpStatusError` and
                      `gcp_status_error` (the generated REST clients'
                      contract); and gRPC statuses: `code_from_grpc_status`,
                      `GcpGrpcStatusError` and `gcp_grpc_status_error` (the
                      generated gRPC clients' contract), and
                      `gcp_grpc_error_code`, which reads the code back out of
                      such an error. Never echoes a body byte or a
                      `grpc-message`.
  - pagination.mojo : `pageToken` / `nextPageToken` paging (AIP-158):
                      `PageCursor`, `next_page_token`, `with_page_token`.
  - retry.mojo      : `GcpRetryClassifier` (AIP-194 retryable codes, with
                      google.rpc.RetryInfo as the server delay) and
                      `gcp_retry_policy` (AIP-4221 backoff); the policy,
                      backoff and loop themselves are komira_retry's.
  - v4_sign.mojo    : Cloud Storage V4 signed URLs (GOOG4-RSA-SHA256):
                      canonical request, string to sign, the RSA signature
                      (komira_crypto) and `gcs_v4_signed_url`. Pure: the
                      signing time is a parameter
                      (`gcs_v4_stamps_from_unix_seconds`).
  - sources.mojo    : the chain's seams: `EnvSource` (`ProcessEnv`,
                      `MapEnv`), `FileSource` (`ProcessFiles`, `MapFiles`),
                      `WallClock` (`SystemWallClock`, `FixedWallClock`).
                      The ONLY file that reads the process environment.
  - token_http.mojo : `GcpHttpTransport`, the fetchers' one exchange, and
                      `GcpConnectorTransport[C]` over komira_http_client;
                      `TokenHttpRequest` / `TokenHttpResponse`.
  - token_wire.mojo : pure: the metadata request and probe, the
                      service-account key and authorized_user files, the
                      RS256 JWTs (grant assertion and self-signed), the
                      grant requests, and the token response and its error.
  - token_sources.mojo : the fetchers: `MetadataServerFetcher`,
                      `ServiceAccountKeyFetcher`, `SelfSignedJwtFetcher`,
                      `AuthorizedUserFetcher`.
  - adc.mojo        : Application Default Credentials: `resolve_adc`,
                      `AdcFetcher`, `application_default_token_source`
                      (and `_with`, over injected seams).
  - _text.mojo      : private, not re-exported: the package's one RFC 3986
                      percent-encoder (`pageToken`, the V4 path and query)
                      and form encoder (the token requests).

Only sources.mojo reads the environment, and only the variables Google's
auth libraries read (adc.mojo, `adc_env_names()`). The only connections the
package opens are the token fetches, over the connectors its caller gives.
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
    GcpGrpcStatusError,
    GcpStatusError,
    code_from_grpc_status,
    code_from_http_status,
    code_from_name,
    code_name,
    gcp_grpc_error_code,
    gcp_grpc_status_error,
    gcp_status_error,
    parse_gcp_status,
    RETRY_INFO_TYPE,
)
from .pagination import (
    DEFAULT_MAX_PAGES,
    PageCursor,
    next_page_token,
    with_page_token,
)
from .retry import GcpRetryClassifier, gcp_retry_policy
from .v4_sign import (
    GCS_V4_ALGORITHM,
    GCS_V4_CONTENT_SHA256_HEADER,
    GCS_V4_DEFAULT_HOST,
    GCS_V4_MAX_EXPIRES_SECONDS,
    GCS_V4_REQUEST_TYPE,
    GCS_V4_SERVICE,
    GCS_V4_UNSIGNED_PAYLOAD,
    GcsV4CanonicalHeaders,
    GcsV4CanonicalRequest,
    GcsV4Header,
    GcsV4QueryParam,
    GcsV4ServiceAccount,
    GcsV4Stamps,
    gcs_v4_build_canonical_request,
    gcs_v4_canonical_headers,
    gcs_v4_canonical_path,
    gcs_v4_canonical_query,
    gcs_v4_credential_scope,
    gcs_v4_sign_string_to_sign,
    gcs_v4_signed_url,
    gcs_v4_stamps_from_unix_seconds,
    gcs_v4_string_to_sign,
)
from .sources import (
    EnvSource,
    FileSource,
    FixedWallClock,
    MapEnv,
    MapFiles,
    ProcessEnv,
    ProcessFiles,
    SystemWallClock,
    WallClock,
)
from .token_http import (
    GcpConnectorTransport,
    GcpHttpTransport,
    TokenHeader,
    TokenHttpRequest,
    TokenHttpResponse,
)
from .token_wire import (
    FORM_CONTENT_TYPE,
    GOOGLE_DEFAULT_UNIVERSE,
    GOOGLE_OAUTH2_TOKEN_URI,
    JWT_BEARER_GRANT_TYPE,
    JWT_LIFETIME_SECONDS,
    METADATA_DEFAULT_HOST,
    METADATA_FLAVOR_HEADER,
    METADATA_FLAVOR_VALUE,
    METADATA_IP,
    METADATA_TOKEN_PATH,
    REFRESH_GRANT_TYPE,
    AuthorizedUser,
    ServiceAccountKey,
    TokenEndpoint,
    authorized_user_from_json,
    authorized_user_refresh_request,
    credentials_type,
    jwt_grant_assertion,
    metadata_endpoint,
    metadata_ping_answered,
    metadata_ping_request,
    metadata_token_request,
    parse_credentials_json,
    parse_service_account_key,
    parse_token_endpoint,
    parse_token_response,
    self_signed_jwt,
    service_account_grant_request,
    service_account_key_from_json,
    token_error,
)
from .token_sources import (
    AuthorizedUserFetcher,
    MetadataServerFetcher,
    SelfSignedJwtFetcher,
    ServiceAccountKeyFetcher,
)
from .adc import (
    ADC_KIND_AUTHORIZED_USER,
    ADC_KIND_METADATA_SERVER,
    ADC_KIND_SELF_SIGNED_JWT,
    ADC_KIND_SERVICE_ACCOUNT,
    ADC_NOT_FOUND,
    ADC_SOURCE_ENV_FILE,
    ADC_SOURCE_GCLOUD_FILE,
    ADC_SOURCE_METADATA,
    ADC_WELL_KNOWN_FILE,
    ENV_APPDATA,
    ENV_CLOUDSDK_CONFIG,
    ENV_GCE_METADATA_HOST,
    ENV_GOOGLE_APPLICATION_CREDENTIALS,
    ENV_HOME,
    GCE_PRODUCT_NAME_FILE,
    PROBE_TIMEOUT_US,
    AdcCredentials,
    AdcFetcher,
    AdcOptions,
    adc_env_names,
    adc_probe_config,
    application_default_token_source,
    application_default_token_source_with,
    gcloud_adc_path,
    resolve_adc,
)
