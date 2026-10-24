# =============================================================================
# komira_secrets_conjur: a `SecretStore` over CyberArk Conjur's REST API.
# =============================================================================
#
#   * `ConjurSecretStore[C, T]`  the store: `resolve("{account}/{variable_id}")`
#                                GETs `/secrets/{account}/variable/{variable_id}`
#                                and returns the 200 body as a zeroizing
#                                `SecretValue`.
#   * `ConjurAuthSource`         the access-token seam.
#     `LiveConjurAuthSource[C]`  mints a token with the authn POST (API key in,
#                                base64 token out).
#     `StaticConjurAuthSource`   a canned token (the double).
#   * `parse_conjur_ref`, `read_path_for`, `build_read_request_headers`,
#     `authn_path_for`, `build_authn_request_headers`  pure request builders.
#
# DEPENDENCIES: komira_secret_store, komira_http_client and komira_http_core (the
# REST client and the `Connector` seam), komira_async (BlockingRuntime),
# komira_crypto.
#
# NOT PROVIDED: the Kubernetes authn login, an access-token cache.
# =============================================================================

from komira_secrets_conjur.conjur_auth_source import (
    ConjurAuthSource,
    LiveConjurAuthSource,
    StaticConjurAuthSource,
    authn_path_for,
    build_authn_request_headers,
)
from komira_secrets_conjur.conjur_secret_store import (
    CONJUR_DEFAULT_PORT,
    CONJUR_SECRETS_PREFIX,
    CONJUR_VARIABLE_KIND,
    ConjurSecretRef,
    ConjurSecretStore,
    build_read_request_headers,
    parse_conjur_ref,
    read_path_for,
)
