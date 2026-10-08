"""`komira_azure_blob` — Azure Blob Storage: Shared Key signing, the store,
the file system and the service SAS signer.

  * `azure_signing` — Shared Key signing (the 13-field string-to-sign) as a
    pure function, and `SharedKeySigningLayer`, an HttpService layer that
    stamps `x-ms-date` and adds `Authorization: SharedKey <account>:<sig>`.
    Shared Key is Storage-specific (it canonicalizes `x-ms-*` headers and the
    storage resource path), so it lives here, not in `komira_azure_core`.
  * `AzureStore` — HEAD, range GET, List Blobs and Put Blob (a block blob
    in one request) over any HttpService,
    real Azure (virtual-hosted) or Azurite (path-style); `azure_xml` reads
    the List Blobs and error bodies.
  * `AzureClient` — the per-worker bundle of HttpClient, signing layer,
    store, connector and reactor; `SasQueryLayer` appends a SAS token to
    each of its requests when it has one.
  * `AzureCredential` (a Shared Key, a SAS token, or anonymous) and
    `AzureClientSpec`, the endpoint, credential and connector factory a
    client is built from.
  * `AzureFs` — komira_fs's `FileSystem` over one container, read-only.
  * `azure_url` — `parse_azure_url` (az://, abfs://, abfss://, the Blob
    service's https:// URL, and an emulator's path-style http:// URL) into
    an `AzureUrl`; `AzureFsConfig` (account, endpoint, path-style) and
    `azure_fs_config_for_url`; `azure_config_for`,
    `azure_endpoint_is_plaintext`, `azure_connector_factory`, `azure_fs_for`
    and `azure_prod_fs`, which build an AzureFs with its credential and pick
    the plaintext connector only for an `http://` endpoint.
  * `AzureSasSigner` — komira_objectstore's `ObjectUrlSigner`, as a blob
    service SAS, signed at the instant its `AzureSasClock` reports at each
    mint (`SystemAzureSasClock` in production, `FixedAzureSasClock` in
    tests).
"""

from .azure import (
    AZURE_ERR_NOT_FOUND,
    AZURE_ERR_PERMISSION_DENIED,
    AZURE_ERR_PRECONDITION,
    AZURE_ERR_THROTTLED,
    AZURE_ERR_TRANSPORT,
    AzureBlobMeta,
    AzureConfig,
    AzureStore,
    azure_store_error_kind_from_message,
    build_azure_blob_url,
    build_azure_listing_url,
)
from .azure_client import AzureClient, AzureClientHttp
from .azure_client_spec import (
    AZURE_CREDENTIAL_ANONYMOUS,
    AZURE_CREDENTIAL_SAS,
    AZURE_CREDENTIAL_SHARED_KEY,
    AzureClientSpec,
    AzureCredential,
)
from .azure_fs import (
    AZURE_LIST_MAX_PAGES,
    AzureFileHandle,
    AzureFs,
    AzureWriteFile,
)
from .azure_sas_query import SasQueryLayer, azure_sas_query_normalize
from .azure_url import (
    AzureFsConfig,
    AzureUrl,
    azure_config_for,
    azure_connector_factory,
    azure_endpoint_is_plaintext,
    azure_fs_config_for_url,
    azure_fs_for,
    azure_prod_fs,
    parse_azure_url,
)
from .azure_signing import (
    SHARED_KEY_EMPTY_ZERO_LENGTH_VERSION,
    AzureSharedKeyProvider,
    AzureSharedKeySigningContext,
    AzureSharedKeyResult,
    SharedKeySigningLayer,
    StaticSharedKeyProvider,
    azure_shared_key_sign,
    build_string_to_sign,
    canonicalize_headers,
    canonicalize_resource,
    shared_key_content_length,
)
from .azure_xml import (
    AzureBlobEntry,
    AzureListBlobsResult,
    AzureParsedError,
    parse_azure_error,
    parse_azure_list_blobs_result,
)

# AZURE BLOB SERVICE SAS — the Azure leg of the cloud-neutral
# presign seam. `AzureSasSigner` conforms to
# `komira_objectstore.ObjectUrlSigner`. It is the conformer that proves the
# seam had to be a trait: no canonical request, a fixed 16-field positional
# string-to-sign, an ABSOLUTE expiry, and a REQUIRED client header on upload.
from .azure_sas import (
    AZURE_SAS_BLOB_TYPE_BLOCK,
    AZURE_SAS_BLOB_TYPE_HEADER,
    AZURE_SAS_PERM_CREATE_WRITE,
    AZURE_SAS_PERM_READ,
    AZURE_SAS_VERSION,
    AzureSasClock,
    AzureSasResult,
    AzureSasSigner,
    FixedAzureSasClock,
    SystemAzureSasClock,
    azure_blob_service_sas,
    azure_sas_canonicalized_resource,
    azure_sas_iso8601_utc,
    azure_sas_signature,
    azure_sas_string_to_sign,
)
