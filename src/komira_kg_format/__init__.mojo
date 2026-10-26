# =============================================================================
# komira_kg_format -- the values and on-disk formats the data-graph writer and
#   reader share (part 1: embeddings, extraction values and the snapshot
#   manifest).
# =============================================================================
#
#   * embedding      -- the packed little-endian f32 embedding cell.
#   * ingest_types   -- `Triple`, `EntityMention`, `Extraction`: what an
#                       extractor returns for one episode.
#   * manifest_body  -- `KgManifestBody`: the snapshot manifest chunk body, which
#                       carries the graph's embedding dimension.
#
# No dependency beyond the standard library, and no clock or environment read.
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
