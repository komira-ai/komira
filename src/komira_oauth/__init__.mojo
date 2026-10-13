# =============================================================================
# komira_oauth — OAuth 2.0 for a service that is a client of an issuer: the
#   `client_credentials` grant with `private_key_jwt` client authentication,
#   the authorization server metadata, and the client registration record.
# =============================================================================
#
#   * `ClientCredentialSource[T]` — one client's access token for one
#     resource, fetched on first use, refreshed 60 s before it expires, and
#     never served after a failed refresh; `fetch_client_credentials_token`
#     is one request. The token endpoint is reached through the
#     `TokenEndpointTransport` trait (client.mojo).
#   * The token endpoint wire: `ClientCredentialsRequest` and
#     `parse_client_credentials_request`, `TokenResponse`,
#     `render_token_response` and `parse_token_response`,
#     `render_oauth_error` and `oauth_error_code` (token_wire.mojo); the form
#     encoding (`FormParams`, `parse_form`, form.mojo).
#   * RFC 8414: `authorization_server_metadata_url`,
#     `AuthorizationServerMetadata` and `parse_authorization_server_metadata`
#     (metadata.mojo).
#   * RFC 7591: `ClientMetadata` and `parse_client_metadata`
#     (client_metadata.mojo).
#
# Every refusal raises `OAuthError: <fixed text>` (`JoseError: ...` from
# komira_jose, `JwksError: ...` never escapes); no text carries a token, an
# assertion or a byte of a body or document.
#
# Dep closure: `komira_jose` (the assertion mint) and its closure:
# `komira_crypto`, `komira_encoding`, `komira_json`, `komira_jwks`,
# `komira_secret_store`.
# =============================================================================

from komira_oauth.form import (
    OAUTH_FORM_MAX_BYTES,
    FormParams,
    form_encode_value,
    parse_form,
)
from komira_oauth.token_wire import (
    OAUTH_ASSERTION_TYPE_JWT_BEARER,
    OAUTH_ERROR_INVALID_CLIENT,
    OAUTH_ERROR_INVALID_GRANT,
    OAUTH_ERROR_INVALID_REQUEST,
    OAUTH_ERROR_INVALID_SCOPE,
    OAUTH_ERROR_INVALID_TARGET,
    OAUTH_ERROR_UNAUTHORIZED_CLIENT,
    OAUTH_ERROR_UNSUPPORTED_GRANT_TYPE,
    OAUTH_GRANT_CLIENT_CREDENTIALS,
    OAUTH_MAX_TOKEN_LIFETIME_S,
    OAUTH_RESPONSE_MAX_BYTES,
    OAUTH_TOKEN_TYPE_BEARER,
    ClientCredentialsRequest,
    ParsedTokenRequest,
    TokenResponse,
    oauth_error_code,
    oauth_error_codes,
    parse_client_credentials_request,
    parse_token_response,
    render_oauth_error,
    render_token_response,
)
from komira_oauth.metadata import (
    OAUTH_AUTH_METHOD_PRIVATE_KEY_JWT,
    OAUTH_METADATA_MAX_BYTES,
    OAUTH_METADATA_WELL_KNOWN,
    AuthorizationServerMetadata,
    authorization_server_metadata_url,
    parse_authorization_server_metadata,
)
from komira_oauth.client_metadata import (
    OAUTH_CLIENT_METADATA_MAX_BYTES,
    ClientMetadata,
    parse_client_metadata,
)
from komira_oauth.client import (
    OAUTH_ASSERTION_TTL_S,
    OAUTH_REFRESH_SKEW_S,
    ClientCredentialSource,
    TokenEndpointReply,
    TokenEndpointTransport,
    fetch_client_credentials_token,
)
