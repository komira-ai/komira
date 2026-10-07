"""`komira_objectstore` — vendor-neutral cloud object-storage abstraction.

The network-free core:
  * Path (normalized /-delimited path; .. / . rejected)
  * objectstore_uri.parse (s3://, gs://, az://, abfs://, file://)
  * types.* (ObjectMeta, GetRange, RangeSet, GetOptions, ListResult,
             CoalescePolicy, StoreError)
  * ObjectStore trait (a narrowed surface — sync metadata only; the
             byte-fetch methods live with the HTTP-backed conformers)
  * ObjectStoreHttpStub trait (the local HTTP-client seam; see the
             notes in store.mojo for how a real client replaces it)
  * RequestCore[Http] (a skeleton parameterized over the
             ObjectStoreHttpStub bound; production HTTP client + the
             in-memory test conformer both monomorphize through it)
  * coalesce.mojo (the range-coalescing PLAN)

The real S3/GCS/Azure backends live in their own per-cloud packages.

Per placement:
  * The abstract `CredentialProvider` trait lives in `komira_core/traits/`
    (NOT in this package) — runtime-free, vendor-neutral, so it sits
    below the per-cloud `_core` packages that conform to it.
  * `ByteBuf` (= `ByteBuffer`) and `ByteBufMut` (= `ByteView[mut=True]`)
    are existing `komira_core/collections/` types — consumed, not
    redefined.
"""

from .path import Path
from .objectstore_uri import (
    ObjectStoreUri,
    Scheme,
    SCHEME_S3,
    SCHEME_GS,
    SCHEME_AZ,
    SCHEME_ABFS,
    SCHEME_FILE,
    parse,
)
from .types import (
    CoalescePolicy,
    GetOptions,
    GetRange,
    GET_RANGE_BOUNDED,
    GET_RANGE_OFFSET,
    GET_RANGE_SUFFIX,
    ListResult,
    ObjectMeta,
    RangeSet,
    StoreError,
    STORE_ERR_NOT_FOUND,
    STORE_ERR_PERMISSION_DENIED,
    STORE_ERR_THROTTLED,
    STORE_ERR_PRECONDITION,
    STORE_ERR_TRANSPORT,
    STORE_ERR_MALFORMED,
    WritePrecondition,
    WRITE_PRECOND_NONE,
    WRITE_PRECOND_IF_NONE_MATCH_STAR,
    WRITE_PRECOND_IF_MATCH,
    WRITE_PRECOND_IF_NONE_MATCH,
)
from .store import (
    AsyncCasStore,
    CAS_OP_ERR,
    CAS_OP_PENDING,
    CAS_OP_READY,
    CasOpProgress,
    CasReadResult,
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    ObjectStoreHttpStub,
)
from .cas_manifest import (
    AppendResult,
    CasManifestStore,
    CatalogSidecar,
    LIFECYCLE_PUBLISHED,
    LIFECYCLE_SCHEDULED_FOR_DELETE,
    LIFECYCLE_STAGED,
    LogStart,
    ManifestHead,
    MetadataStore,
    RetryPolicy,
    catalog_key,
    chunk_key,
    decode_chunk_body,
    decode_chunk_record_count,
    decode_head,
    decode_log_start,
    encode_chunk,
    encode_head,
    encode_log_start,
    head_key,
    lifecycle_name,
    log_start_key,
    moved_tombstone_key,
    tombstone_key,
)
# The object-store READINESS predicate every object-store-backed managed app answers
# `GET /healthz` with: ONE sentinel-prefix hierarchical listing, which
# unlike a `head` on a missing object — separates "bucket absent / unauthorized"
# (error => NOT ready) from "prefix empty" (success => ready).
from .store_readiness import (
    object_store_reachable,
    STORE_READINESS_PROBE_PREFIX,
)
from .in_memory_conditional_store import InMemoryConditionalStore
from .delimiter_faithful_conditional_store import (
    DelimiterFaithfulConditionalStore,
)
from .shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from .shared_in_memory_slow_cas_store import SharedInMemorySlowCasStore
from .shared_in_memory_latency_store import SharedInMemoryLatencyStore
from .local_fs_conditional_store import LocalFsConditionalStore
from .request_core import RequestCore
from .coalesce import (
    AbsoluteRange,
    CoalescePlan,
    CoalescedRange,
    OriginalSlice,
    plan_coalesce,
)
# The neutral, low-level shard-id + sub-lineage PATH KERNEL. It lives here,
# low in the dependency graph, so the pgsql/table-store index-sharding path can
# reuse it WITHOUT importing the search packages; the search metastore
# re-exports it.
from .sublineage_shard_keys import (
    LINEAGE_BASE_SHARD,
    is_reserved_shard_id,
    make_shard_id,
    shard_manifest_prefix,
    _discover_shard_ids,
)

# PRESIGN SEAM — the cloud-neutral `ObjectUrlSigner` trait plus the
# `PresignedUrl` value it mints. See presign.mojo's header for why this is a
# trait and not a GCS function: a managed app deploys into the CUSTOMER's cloud,
# and all three object stores have this primitive with a different algorithm.
from .presign import (
    PRESIGN_MAX_TTL_SECONDS,
    presign_percent_encode,
    presign_is_unreserved,
    PRESIGN_MIN_TTL_SECONDS,
    ObjectUrlSigner,
    PresignedHeader,
    PresignedUrl,
    check_presign_ttl,
)
