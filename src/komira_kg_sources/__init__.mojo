# =============================================================================
# komira_kg_sources -- the host-neutral half of source handling.
# =============================================================================
#
# What a host needs between fetching a record and putting its episodes in the
# graph, with no adapter for any particular kind of record or service in it:
#
#   * raw_store          -- `RawStore`, `RawRecord`, `RawPut`: raw payloads kept
#                           once each under their content hash, the surface tag
#                           an opaque label on the record.
#   * partition_binding  -- `PartitionBinding`, `PartitionBindingStore`: the one
#                           raw store and the one lineage a partition uses, and
#                           its source system, kind and facet, checked against
#                           sets the host passes in.
#   * adapter_registry   -- `RawSurfaceAdapter`, `AdapterRegistry`,
#                           `EmptyAdapterRegistry`, `RegisteredAdapter`,
#                           `register`: a surface tag mapped to the adapter that
#                           parses and lowers its raw bytes.
#   * b_index            -- `BIndex`, `BIndexHit`, `BIndexBuild`, `episode_of`:
#                           a brute-force cosine index over the episodes the
#                           registry lowers raw records to.
#   * framing            -- the bounds-checked byte helpers the stored objects use.
# =============================================================================

from .raw_store import (
    RAW_FORMAT_VERSION,
    RawPut,
    RawRecord,
    RawStore,
    check_same_payload,
    decode_raw_record,
    encode_raw_record,
    raw_content_hash,
)
from .partition_binding import (
    BINDING_FORMAT_VERSION,
    PartitionBinding,
    PartitionBindingStore,
    decode_binding,
    encode_binding,
)
from .adapter_registry import (
    AdapterRegistry,
    EmptyAdapterRegistry,
    RawSurfaceAdapter,
    RegisteredAdapter,
    register,
)
from .b_index import (
    INDEX_FORMAT_VERSION,
    BIndex,
    BIndexBuild,
    BIndexHit,
    IndexRecord,
    IndexRow,
    decode_index_record,
    encode_index_record,
    episode_of,
)
from .framing import FIELD_MAX_BYTES
