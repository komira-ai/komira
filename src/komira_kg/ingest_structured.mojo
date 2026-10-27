# =============================================================================
# ingest_structured -- ingest facts a caller already knows: no extraction.
# =============================================================================
#
# `ingest_structured_into` takes a `StructuredEpisode`: the entities and triples
# themselves (an `Extraction` built by the caller from a record whose facts are
# exact) with the same provenance envelope an `EpisodeInput` carries, minus the
# text. The extractor is never called; the embedder still names each new entity
# (the name vector is what a later mention is matched against), and the
# same-entity and contradiction judgments are still asked of the `LlmClient`
# where the cascade and the intervals call for them. A caller that wants no model
# at all passes a stub whose judgments are all "no".
#
#   1. refuse a knob or an embedder the graph cannot use;
#   2. the change gate: if the stored hash of `(partition_id, key)` equals the
#      hash of the extraction, nothing changed (the key is the `source` when
#      there is one, else the `uuid`); return the head, embed nothing;
#   3. `write_extraction` with `structured`: a triple's end time is stored; with a
#      `source`, unchanged triples are skipped (the per-symbol diff) and an edge
#      the source held that no triple states is closed (the removal);
#   4. record the extraction's hash for the next change gate.
#
# The hash covers the extraction alone (entities and triples with their times),
# not `body`, `ts`, `valid_at` or the facet: re-sending the same facts is a no-op
# whatever the envelope says. Its order matters; the same facts in another order
# are a change (and then change nothing but the episode row).
#
# FAILURE as for `ingest_episode_into`: a refusal or an error from the embedder
# or the model is raised before the first store write, so the store is unchanged;
# the working set may be half-edited and is discarded.
# =============================================================================

from komira_kg_format import (
    Extraction,
    KgSnapshotStore,
    SnapshotId,
    content_hash_of_extraction,
)
from komira_objectstore.store import CloneableConditionalWriteStore

from .embedder import Embedder
from .ingest import write_extraction
from .ingest_config import IngestConfig
from .llm_client import LlmClient
from .working_set import SnapshotWorkingSet


struct StructuredEpisode(Movable):
    """Known entities and triples with their provenance envelope.

    Fields:
        uuid: The stable external id; the episode row's id, and the change gate's
            key when `source` is empty.
        partition_id: The opaque id of the partition the facts belong to.
        extraction: The entities and triples, held in an `Optional` so ingest can
            move them out (`take_extraction`).
        ts: The system (ingest) time, stamped as `created_at`.
        valid_at: The event time the facts refer to; the default `valid_at` of an
            undated triple.
        body: A short provenance note for the episode row, "" for none. It is
            never extracted from.
        source: The id of the source these facts come from, unique within the
            partition, "" for none. A non-empty source replaces what that source
            held: see the file header of `ingest_source_diff`. It is also the
            change gate's key.
        facet: An opaque label for the kind of source, "" for none.
        facet_source: The id of the source the facet is attributed to, "" for
            none.
    """

    var uuid: String
    var partition_id: String
    var extraction: Optional[Extraction]
    var ts: Int64
    var valid_at: Int64
    var body: String
    var source: String
    var facet: String
    var facet_source: String

    def __init__(
        out self,
        var uuid: String,
        var partition_id: String,
        var extraction: Extraction,
        ts: Int64,
        valid_at: Int64,
        var body: String = String(""),
        var source: String = String(""),
        var facet: String = String(""),
        var facet_source: String = String(""),
    ):
        """A structured episode; every field after `valid_at` is "" by default."""
        self.uuid = uuid^
        self.partition_id = partition_id^
        self.extraction = Optional[Extraction](extraction^)
        self.ts = ts
        self.valid_at = valid_at
        self.body = body^
        self.source = source^
        self.facet = facet^
        self.facet_source = facet_source^

    def take_extraction(mut self) raises -> Extraction:
        """Move the extraction out, leaving none.

        Raises:
            If it was already taken.
        """
        if not self.extraction:
            raise Error("StructuredEpisode: the extraction was already taken")
        return self.extraction.take()


def ingest_structured_into[
    Store: CloneableConditionalWriteStore,
    Llm: LlmClient,
    Emb: Embedder,
](
    mut store: KgSnapshotStore[Store],
    mut ws: SnapshotWorkingSet,
    var episode: StructuredEpisode,
    ref llm: Llm,
    ref emb: Emb,
    cfg: IngestConfig,
) raises -> SnapshotId:
    """Ingest known facts into the graph, through a working set the caller holds
    (loaded from the store's head, or empty for an empty lineage). See the file
    header for the steps.

    Parameters:
        Store: The object store (inferred).
        Llm: The model client (inferred); only the two judgments are called.
        Emb: The embedder (inferred).

    Args:
        store: The snapshot store.
        ws: The working set; committed after a successful write, to be discarded
            after an error.
        episode: The facts (consumed).
        llm: The model client (`judge_same_entity`, `judge_contradiction`).
        emb: The embedder; its dimension must be the set's.
        cfg: The ingest knobs.

    Returns:
        The new head, or the current head if the extraction was unchanged.

    Raises:
        If `cfg` is invalid, the embedder's dimension is not the set's, the
        extraction was already taken, a triple with an end time ends at or before
        its start, the model or embedder raises, an embedding is not the graph's
        dimension, or the store fails. See the file header for what an error
        leaves behind.
    """
    cfg.check()
    if emb.dimension() != ws.embedding_dim:
        raise Error(
            "ingest_structured: the embedder's dimension is "
            + String(emb.dimension())
            + " but the graph's is "
            + String(ws.embedding_dim)
        )
    var extraction = episode.take_extraction()
    var key = String(episode.source)
    if len(key.as_bytes()) == 0:
        key = String(episode.uuid)
    var content_hash = content_hash_of_extraction(extraction)
    var prior = store.fingerprint_lookup(episode.partition_id, key)
    if len(prior.as_bytes()) > 0 and prior == content_hash:
        return store.latest_snapshot_id()
    var new_head = write_extraction(
        store,
        ws,
        extraction^,
        llm,
        emb,
        episode.uuid,
        episode.partition_id,
        episode.body,
        episode.ts,
        episode.valid_at,
        cfg,
        episode.facet,
        episode.facet_source,
        episode.source,
        True,
    )
    store.fingerprint_patch_save(
        String(episode.partition_id), key^, content_hash^, String("")
    )
    return new_head


def ingest_structured[
    Store: CloneableConditionalWriteStore,
    Llm: LlmClient,
    Emb: Embedder,
](
    mut store: KgSnapshotStore[Store],
    var episode: StructuredEpisode,
    ref llm: Llm,
    ref emb: Emb,
    cfg: IngestConfig,
) raises -> SnapshotId:
    """Ingest known facts, loading the working set from the store's head (an
    empty set of the embedder's dimension for an empty lineage).

    Parameters:
        Store: The object store (inferred).
        Llm: The model client (inferred).
        Emb: The embedder (inferred).

    Args:
        store: The snapshot store.
        episode: The facts (consumed).
        llm: The model client.
        emb: The embedder.
        cfg: The ingest knobs.

    Returns:
        The new head, or the current head if the extraction was unchanged.

    Raises:
        As `ingest_structured_into`, and if the head cannot be loaded.
    """
    if store.latest_snapshot_id() < Int64(0):
        var empty = SnapshotWorkingSet(emb.dimension())
        return ingest_structured_into(store, empty, episode^, llm, emb, cfg)
    var ws = SnapshotWorkingSet.load_latest(store)
    return ingest_structured_into(store, ws, episode^, llm, emb, cfg)
