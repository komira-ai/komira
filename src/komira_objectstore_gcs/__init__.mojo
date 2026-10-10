"""`komira_objectstore_gcs` — Google Cloud Storage over the komira_objectstore
traits.

  * `GcsStorageBackend` (backend.mojo) — the narrow object-verb seam every GCS
    conformer here is generic over, with its value carriers `ObjectMetaRaw`
    and `ListPageRaw`.
  * `FakeGcsStorageBackend` (fake_backend.mojo) — an in-memory conformer of
    the seam with GCS generation semantics. A public test double: no socket,
    no credentials.
  * `GcsConditionalStore[B]` (conditional_store.mojo) — the
    `CloneableConditionalWriteStore` conformer over the seam.
  * `GcsFs[B]` (gcs_fs.mojo) — the `FileSystem` read conformer over the seam.
  * `GCS_ERR_*` / `gcs_store_error_kind_from_message` (errors.mojo) — the
    reader for the `StoreError[<KIND>]` message every backend raises.
  * `GcsV4Signer[C]` (signer.mojo) — the `ObjectUrlSigner` conformer: V4
    signed URLs (komira_gcp_core's GOOG4-RSA-SHA256) for one bucket, signed
    at the instant a caller-supplied `GcsSigningClock` reports.
    `SystemSigningClock` is the process wall clock (komira_clock), the
    one a deployed signer uses; `FixedSigningClock` is a clock stopped at one
    instant, for tests.

  * `StorageGrpcBackend[C, T, K]` (grpc_backend.mojo) — the production
    conformer of `GcsStorageBackend`: google.storage.v2 over gRPC through the
    generated `komira_gcp_storage` client, on connector `C`
    (`GcsTlsConnector`, built by `build_gcs_tls_connector` with public-CA
    trust, or by `build_gcs_tls_connector_trusting(root_pem, server_name)`
    trusting one private root, verification still on), a
    `komira_gcp_core.GcpTokenSource` `T` and a komira_retry
    `MonotonicClock` `K`. `gcs_error_kind_from_code` /
    `gcs_store_error_from_code` map a gRPC status onto the `GCS_ERR_*` kinds.
  * `crc32c` / `crc32c_extend` (crc32c.mojo) — CRC-32C (Castagnoli), the
    checksum the gRPC backend states for each write and checks on each read.
"""

from .backend import GcsStorageBackend, ListPageRaw, ObjectMetaRaw
from .conditional_store import GcsConditionalStore
from .crc32c import crc32c, crc32c_extend
from .errors import (
    GCS_ERR_MALFORMED,
    GCS_ERR_NONE,
    GCS_ERR_NOT_FOUND,
    GCS_ERR_PERMISSION_DENIED,
    GCS_ERR_PRECONDITION,
    GCS_ERR_THROTTLED,
    GCS_ERR_TRANSPORT,
    gcs_store_error_kind_from_message,
)
from .fake_backend import FakeGcsStorageBackend
from .gcs_fs import GcsFileHandle, GcsFs, GcsWriteFile
from .grpc_backend import (
    GCS_DEFAULT_CALL_DEADLINE_MS,
    GCS_GRPC_HOST,
    GCS_GRPC_PORT,
    WRITE_OBJECT_CHUNK_BYTES,
    GcsTlsConnector,
    StorageGrpcBackend,
    build_gcs_tls_connector,
    build_gcs_tls_connector_trusting,
    gcs_bucket_resource_name,
    gcs_error_kind_from_code,
    gcs_routing_param,
    gcs_store_error_from_code,
    gcs_store_error_from_raised,
)
from .signer import (
    GCS_SIGNER_CLOUD,
    GCS_V4_DEFAULT_LOCATION,
    FixedSigningClock,
    GcsSigningClock,
    GcsV4Signer,
    SystemSigningClock,
)
