# =============================================================================
# komira_kg_format -- the values and on-disk formats the data-graph writer and
#   reader share (parts 1 to 5: embeddings, extraction values, the snapshot
#   manifest, table schemas, cosine ranking, the query result, the delta layer,
#   the source fingerprints, the snapshot lineage store and the exact searches).
# =============================================================================
#
#   * embedding      -- the packed little-endian f32 embedding cell.
#   * ingest_types   -- `Triple`, `EntityMention`, `Extraction`: what an
#                       extractor returns for one episode.
#   * manifest_body  -- `KgManifestBody`: the snapshot manifest chunk body, which
#                       carries the graph's embedding dimension.
#   * schemas        -- the Arrow schema of each graph table and its version.
#   * cosine         -- `cosine` and `cosine_topk`, exact cosine ranking over a
#                       packed-embedding column.
#   * query_result   -- `KgQueryResult` and its record types, with a JSON wire.
#   * delta_body    -- `KgDeltaBody`, `KgChainBody`, `KgNameIndexBody`: the chunk
#                       bodies of the delta layer over a base snapshot.
#   * delta_codec   -- the delta object, framed for a few rows and Parquet for
#                       more.
#   * source_fingerprint -- `SourceFingerprintSet` and its lineage store: the
#                       change gate keyed by partition and source.
#   * chunk_kind    -- `kg_chunk_kind`: base, chain head or delta, read from a
#                       chunk's format version.
#   * compaction_policy -- `CompactionPolicy`: when a chain is worth folding.
#   * snapshot_view, chain_view -- `SnapshotView` and `ChainView`: a resolved
#                       base and a resolved chain, with the handle to fetch
#                       their objects.
#   * search        -- `node_similarity_search`, `edge_fulltext_search`,
#                       `edge_out_degree` and `rrf_fuse`: exact scans over a
#                       snapshot's tables, and rank fusion.
#   * snapshot_store -- `KgSnapshotStore`: the lineage on an object store (bases,
#                       delta chains, folds, fingerprints), and `KgTable`.
#
# Depends on `komira_arrow` (and its closure) and `komira_json`, and reads no clock or environment.
# =============================================================================

from .embedding import (
    EMB_F32_BYTES,
    pack_embedding,
    pack_embedding_f32,
    unpack_embedding,
    unpack_embedding_bytes,
    unpack_embedding_checked,
)
from .ingest_types import EntityMention, Extraction, Triple
from .manifest_body import (
    KG_SNAPSHOT_FORMAT_VERSION,
    KgManifestBody,
    KgTableEntry,
)
from .schemas import (
    SCHEMA_VERSION_COMMUNITIES,
    SCHEMA_VERSION_COMMUNITY_REPORTS,
    SCHEMA_VERSION_EDGES,
    SCHEMA_VERSION_ENTITIES,
    SCHEMA_VERSION_ENTITIES_EMBEDDING,
    SCHEMA_VERSION_EPISODES,
    TS_OPEN_SENTINEL,
    communities_schema,
    community_reports_schema,
    edges_schema,
    edges_tombstone_schema,
    entities_embedding_schema,
    entities_schema,
    episodes_schema,
)
from .cosine import Hit, cosine, cosine_topk
from .query_result import (
    KG_QUERY_RESULT_FORMAT_VERSION,
    KgQueryResult,
    Locus,
    ProvenanceEntry,
    ResultEdge,
    ResultAnnotation,
    ResultNode,
    ScoreEntry,
)
from .delta_body import (
    KG_CHAIN_FORMAT_VERSION,
    KG_DELTA_FORMAT_VERSION,
    KgChainBody,
    KgDeltaBody,
    KgDeltaTableEntry,
    KgNameIndexBody,
    KgNameIndexEntry,
    kg_chunk_is_chain_head,
)
from .delta_codec import (
    FRAME_TAG_FRAMED,
    FRAME_TAG_PARQUET,
    FRAMED_CODEC_VERSION,
    FRAMED_MAX_ROWS,
    decode_framed_delta_to_batch,
    delta_object_is_framed,
    delta_object_parquet_bytes,
    encode_delta_table_object,
    framed_object_size,
    framed_size_is_decodable,
)
from .source_fingerprint import (
    KG_FINGERPRINT_FORMAT_VERSION,
    SourceFingerprint,
    SourceFingerprintSet,
    SourceFingerprintStore,
    content_hash_of,
    content_hash_of_extraction,
    fnv1a64_hex,
)
from .chunk_kind import (
    KG_CHUNK_BASE,
    KG_CHUNK_CHAIN,
    KG_CHUNK_DELTA,
    kg_chunk_kind,
)
from .compaction_policy import CompactionPolicy
from .snapshot_view import SnapshotId, SnapshotView
from .chain_view import ChainView
from .snapshot_store import (
    DEFAULT_MAX_HEAD_ATTEMPTS,
    PENDING_BASE_RECORD_COUNT,
    KgSnapshotStore,
    KgTable,
)
from .search import (
    edge_fulltext_search,
    edge_out_degree,
    node_similarity_search,
    rrf_fuse,
)
