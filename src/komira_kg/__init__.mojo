# =============================================================================
# komira_kg -- the mutable data-graph store and its ingest (parts 1 and 2:
#   bi-temporal edges, entity resolution, the source facet and the model seams).
# =============================================================================
#
#   * bitemporal       -- `WorkingEdge`, `open_edge`,
#                         `overlapping_contradiction_candidates`,
#                         `apply_invalidation`: a replaced fact is closed, not
#                         erased.
#   * name_similarity  -- `normalize_name`, `shannon_entropy`,
#                         `minhash_signature`, `jaccard_estimate`,
#                         `lsh_candidate`, `pair_decision`.
#   * dedup            -- `DedupCandidate`, `Resolution`, `dedup_resolve`, and
#                         `SameEntityJudge` with `dedup_resolve_judged`.
#   * alias_map        -- `AliasMap`, a directed union-find over node ids.
#   * source_facet     -- the facet an entity carries in its `attrs`, and
#                         `FacetTombstoneSet`, keyed by source and facet.
#   * embedder         -- the `Embedder` trait (text to a vector of a reported
#                         dimension) and `StubEmbedder`.
#   * extractor        -- the `Extractor` trait (text to an `Extraction`
#                         without inference), `StubExtractor`, `copy_extraction`.
#   * llm_client       -- the `LlmClient` trait (extraction, two judgments,
#                         optional synthesis) and `StubLlmClient`.
#
# Depends on `komira_kg_format` and `komira_json` and their closure. Reads no
# clock and no environment; a time is always an argument.
# =============================================================================

from .alias_map import AliasMap
from .bitemporal import (
    WorkingEdge,
    apply_invalidation,
    open_edge,
    overlapping_contradiction_candidates,
)
from .dedup import (
    DedupCandidate,
    RES_MATCHED,
    RES_NEEDS_JUDGMENT,
    RES_NEW,
    Resolution,
    SameEntityJudge,
    dedup_resolve,
    dedup_resolve_judged,
)
from .name_similarity import (
    LSH_NUM_BANDS,
    MINHASH_NUM_PERM,
    PAIR_ESCALATE,
    PAIR_MERGE,
    PAIR_NONE,
    SHINGLE_K,
    jaccard_estimate,
    lsh_candidate,
    minhash_signature,
    normalize_name,
    pair_decision,
    shannon_entropy,
)
from .source_facet import (
    FACET_ATTR_KEY,
    FACET_SOURCE_ATTR_KEY,
    FacetTombstoneSet,
    facet_attrs_json,
    facet_from_attrs,
    facet_source_from_attrs,
)
from .embedder import STUB_CHAR_CLASSES, Embedder, StubEmbedder
from .extractor import Extractor, StubExtractor, copy_extraction
from .llm_client import LlmClient, StubLlmClient
