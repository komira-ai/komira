# =============================================================================
# komira_secrets_azure: a `SecretStore` over Azure Key Vault.
# =============================================================================
#
#   * `AzureKeyVaultStore[C, T]`  the store: `resolve("https://{vault}.vault.azure.net/
#                                 secrets/{name}[/{version}]")` GETs the secret
#                                 and returns its `value` as a zeroizing
#                                 `SecretValue`.
#   * `AzureTokenSource`          the Entra access-token seam.
#     `ServicePrincipalTokenSource[C]`, `ManagedIdentityTokenSource[C]`  the live
#                                 sources, over komira_azure_core's providers
#                                 with the audience set to Key Vault.
#     `StaticAzureTokenSource`    a canned token (the double).
#   * `parse_key_vault_ref`, `build_kv_request_headers`  pure request builders.
#
# DEPENDENCIES: komira_secret_store, komira_azure_core, komira_http_client and
# komira_http_core (the REST client and the `Connector` seam), komira_async
# (BlockingRuntime), komira_retry (the providers' clock), komira_crypto.
# =============================================================================

from komira_secrets_azure.azure_token_source import (
    AZURE_KV_IMDS_RESOURCE,
    AZURE_KV_SP_SCOPE,
    AzureTokenSource,
    ManagedIdentityTokenSource,
    ServicePrincipalTokenSource,
    StaticAzureTokenSource,
)
from komira_secrets_azure.azure_key_vault_store import (
    AZURE_KV_API_VERSION,
    AZURE_KV_DNS_SUFFIX,
    AZURE_KV_PORT,
    AZURE_KV_SECRETS_SEGMENT,
    AzureKeyVaultStore,
    KeyVaultRef,
    build_kv_request_headers,
    parse_key_vault_ref,
)
