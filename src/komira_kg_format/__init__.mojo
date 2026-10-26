# =============================================================================
# komira_kg_format -- the values and on-disk formats the data-graph writer and
#   reader share (part 1: embeddings, extraction values, JSON values and the
#   snapshot manifest).
# =============================================================================
#
#   * embedding      -- the packed little-endian f32 embedding cell.
#   * ingest_types   -- `Triple`, `EntityMention`, `Extraction`: what an
#                       extractor returns for one episode.
#   * json_value     -- `JsonDoc` and `JsonValue`: a small strict JSON reader.
#   * manifest_body  -- `KgManifestBody`: the snapshot manifest chunk body, which
#                       carries the graph's embedding dimension.
#
# No dependency beyond the standard library, and no clock or environment read.
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
    KG_SNAPSHOT_FORMAT_VERSION_MIN,
    KgManifestBody,
    KgTableEntry,
)
