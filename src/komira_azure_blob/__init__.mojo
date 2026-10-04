"""`komira_azure_blob` — Azure Blob Storage: Shared Key signing, the store,
the file system and the service SAS signer.

  * `azure_signing` — Shared Key signing (the 13-field string-to-sign) as a
    pure function, and `SharedKeySigningLayer`, an HttpService layer that
    stamps `x-ms-date` and adds `Authorization: SharedKey <account>:<sig>`.
    Shared Key is Storage-specific (it canonicalizes `x-ms-*` headers and the
    storage resource path), so it lives here, not in `komira_azure_core`.
  * `AzureStore` — HEAD, range GET and List Blobs over any HttpService,
    real Azure (virtual-hosted) or Azurite (path-style); `azure_xml` reads
    the List Blobs and error bodies.
  * `AzureClient` — the per-worker bundle of HttpClient, signing layer,
    store, connector and reactor.
  * `AzureFs` — komira_fs's `FileSystem` over one container, read-only.
  * `AzureSasSigner` — komira_objectstore's `ObjectUrlSigner`, as a blob
    service SAS.
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
from .azure_client import AzureClient
from .azure_fs import AzureFileHandle, AzureFs, AzureWriteFile
from .azure_signing import (
    AzureSharedKeyProvider,
    AzureSharedKeySigningContext,
    AzureSharedKeyResult,
    SharedKeySigningLayer,
    StaticSharedKeyProvider,
    azure_shared_key_sign,
    build_string_to_sign,
    canonicalize_headers,
    canonicalize_resource,
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
    AzureSasResult,
    AzureSasSigner,
    azure_blob_service_sas,
    azure_sas_canonicalized_resource,
    azure_sas_iso8601_utc,
    azure_sas_signature,
    azure_sas_string_to_sign,
)
