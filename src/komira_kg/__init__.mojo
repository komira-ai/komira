# =============================================================================
# komira_kg -- the mutable data-graph store and its ingest (parts 1 to 6:
#   bi-temporal edges, entity resolution, the source facet, the model seams, the
#   rule-driven extractor, the source cursor store and the in-memory working
#   set, erasure, the warm cache, compaction, embedding top-k and the episode
#   ingest path).
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
#   * rule             -- `Rule`: one extraction rule (a type label and a
#                         matcher), all of it host data.
#   * rule_pattern     -- `Pattern`: a whole-token byte pattern.
#   * rule_scan        -- `scan_rule`, `tokens_of`: what a rule finds in a text.
#   * rule_extractor   -- `RuleExtractor`: an `Extractor` driven by a rule set.
#   * cursor_store     -- `SurfaceCursor` and `CursorStore`: where an incremental
#                         read of a source stopped, kept with compare-and-set on
#                         a conditional-write store.
#   * working_rows     -- `WorkingEntity` and `WorkingEpisode` (with the edges of
#                         `bitemporal`, the rows of the working set).
#   * working_codec    -- the table names, and the checked conversion between
#                         the snapshot's table batches and working rows.
#   * working_set      -- `SnapshotWorkingSet`: load a snapshot or a delta chain,
#                         apply changes, write back a base or only the delta.
#   * rewrite          -- `base_tables_of`, `append_index_bootstrap`,
#                         `finish_rewrite`, `repair_missing_bootstrap`: the
#                         base and the index delta a rewrite of a whole graph
#                         writes, and finishing or repairing one.
#   * erase            -- `erase_partition`, `erase_kg_partition`: remove one
#                         partition's rows and embeddings (`erase_kg_partition_at`
#                         and `erase_commit_at` hold the erasure open).
#   * warm_cache       -- `WarmMergedCache`: the merged graph kept in memory,
#                         keyed by the head; lent read-only.
#   * compaction       -- `compact_chain`, `compact_chain_at`,
#                         `maybe_compact_chain`: fold a delta chain into a base
#                         (`compact_commit_at` holds the fold open).
#   * embedding_topk   -- `resolve_embedding_topk`: the nearest entities to a
#                         vector, from the deltas' embedding projection.
#   * ingest_config    -- `IngestConfig` (the knobs of one ingest) and
#                         `EpisodeInput` (one source text with its provenance).
#   * ingest_gleaning  -- `run_gleaning`: the bounded extraction loop.
#   * ingest_resolve   -- `resolve_entities`, `existing_nid_for_name`,
#                         `mint_entity`: mentions to entities of the working set.
#   * ingest_edges     -- `apply_edges`: triples to bi-temporal edges.
#   * ingest           -- `ingest_episode`, `ingest_episode_into`,
#                         `write_extraction`: extract, resolve, apply, store.
#
# Depends on `komira_kg_format`, `komira_json` and `komira_objectstore` and their
# closure (the snapshot store, the schemas, the delta codec and the Parquet reader). Reads no
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
from .rule import (
    RULE_DELIMITED,
    RULE_EMAIL,
    RULE_MAX_SPAN_BYTES,
    RULE_TOKEN_PATTERN,
    RULE_URL,
    RULE_VERB_PREFIX,
    RULE_WORD_LIST,
    Rule,
)
from .rule_pattern import PATTERN_MAX_BYTES, Pattern
from .rule_scan import scan_rule, tokens_of
from .rule_extractor import RuleExtractor
from .cursor_store import (
    CURSOR_FORMAT_VERSION,
    CURSOR_MAX_FIELD_BYTES,
    CursorRead,
    CursorStore,
    SurfaceCursor,
    decode_cursor,
    encode_cursor,
)
from .working_rows import WorkingEntity, WorkingEpisode
from .working_codec import (
    EdgeClosure,
    TABLE_EDGES,
    TABLE_EDGES_TOMBSTONE,
    TABLE_ENTITIES,
    TABLE_ENTITIES_EMBEDDING,
    TABLE_EPISODES,
    check_embedding,
)
from .working_set import SnapshotWorkingSet
from .working_codec import ProjectionRows, decode_embedding_projection
from .rewrite import (
    CommittedRewrite,
    append_index_bootstrap,
    base_tables_of,
    finish_rewrite,
    repair_missing_bootstrap,
)
from .erase import (
    ErasureReport,
    MAX_ERASE_ROUNDS,
    erase_commit_at,
    erase_kg_partition,
    erase_kg_partition_at,
    erase_partition,
)
from .warm_cache import WarmMergedCache
from .compaction import (
    CompactionResult,
    compact_chain,
    compact_chain_at,
    compact_commit_at,
    maybe_compact_chain,
)
from .embedding_topk import EmbeddingCandidate, resolve_embedding_topk
from .ingest_config import EpisodeInput, IngestConfig
from .ingest_gleaning import run_gleaning
from .ingest_resolve import existing_nid_for_name, mint_entity, resolve_entities
from .ingest_edges import apply_edges
from .ingest import (
    CROSS_UNIT_CONTEXT_MAX,
    ingest_episode,
    ingest_episode_into,
    write_extraction,
)
