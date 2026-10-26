# =============================================================================
# komira_kg_format -- the values and on-disk formats the data-graph writer and
#   reader share (parts 1 and 2: embeddings, extraction values, JSON values,
#   the snapshot manifest, table schemas, cosine ranking and the query result).
# =============================================================================
#
#   * embedding      -- the packed little-endian f32 embedding cell.
#   * ingest_types   -- `Triple`, `EntityMention`, `Extraction`: what an
#                       extractor returns for one episode.
#   * json_value     -- `JsonDoc` and `JsonValue`: a small strict JSON reader.
#   * manifest_body  -- `KgManifestBody`: the snapshot manifest chunk body, which
#                       carries the graph's embedding dimension.
#   * schemas        -- the Arrow schema of each graph table and its version.
#   * cosine         -- `cosine` and `cosine_topk`, exact cosine ranking over a
#                       packed-embedding column.
#   * query_result   -- `KgQueryResult` and its record types, with a JSON wire.
#
# Depends on `komira_arrow` (and its closure) and `komira_json`, and reads no clock or environment.
# =============================================================================

from .embedding import (
    DEFAULT_EMBEDDING_DIM,
    EMB_F32_BYTES,
    pack_embedding,
    pack_embedding_f32,
    unpack_embedding,
    unpack_embedding_bytes,
    unpack_embedding_checked,
)
from .ingest_types import EntityMention, Extraction, Triple
from .json_value import (
    JSON_ARRAY,
    JSON_BOOL,
    JSON_MAX_DEPTH,
    JSON_NULL,
    JSON_NUMBER,
    JSON_OBJECT,
    JSON_STRING,
    JsonDoc,
    JsonValue,
)
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
