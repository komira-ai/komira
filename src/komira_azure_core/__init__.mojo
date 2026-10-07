"""`komira_azure_core` — Azure-wide credentials (not Storage-specific).

  * the credential types: `AzureSharedKey` (account + key), `AzureSas`, and a
    static provider for each;
  * `AzureBearerToken`, and `parse_oauth_token_response`, the JSON reader of
    a token endpoint's answer;
  * `AzureImdsProvider` — managed identity, through the Azure Instance
    Metadata Service;
  * `ServicePrincipalProvider` — the Entra client-credentials grant.

Both token providers keep their token's expiry on a komira_retry
`MonotonicClock` parameter, `SystemClock` by default; `with_clock` swaps it.

Every setting is a parameter; the package reads no environment. Shared Key
SIGNING is Storage-specific (it canonicalizes `x-ms-*` headers and the storage
resource path), so it lives in `komira_azure_blob`, with the store.
"""

from .azure_token import (
    AzureBearerToken,
    OAuthTokenResponse,
    parse_oauth_token_response,
)
from .creds_managed_identity import AzureImdsProvider
from .creds_service_principal import ServicePrincipalProvider
from .credentials import (
    AzureSas,
    AzureSharedKey,
    SasProvider,
    SharedKeyProvider,
)
