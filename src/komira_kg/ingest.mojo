# =============================================================================
# ingest -- ingest one episode: extract, resolve, apply, store.
# =============================================================================
#
# `ingest_episode_into` is the whole path for one `EpisodeInput`, against a
# working set the caller holds:
#
#   1. refuse a knob or an embedder the graph cannot use;
#   2. the change gate: if the stored content hash of `(partition_id, uuid)`
#      equals the hash of the body, nothing changed; return the head and call no
#      model;
#   3. extract with the bounded gleaning loop (`run_gleaning`);
#   4. `write_extraction`: resolve each mention to an entity, apply each triple as
#      a bi-temporal edge, append the episode row, and persist;
#   5. record the body's hash for the next change gate.
#
# PERSISTING. On an empty lineage the set is written as a base snapshot. On an
# existing lineage only what changed since the set was loaded is appended as a
# delta. Either way the set is then declared committed (`mark_committed`), so a
# resident set can take the next episode and its delta carries that episode
# alone. If the delta cannot say what changed (two open edges share the key a
# tombstone closes by; see `SnapshotWorkingSet`), the whole set is written as a
# new base, followed by the index bootstrap a base lacks, provided the head is
# still the one at the start of this call (the set may have been loaded from an
# older head; ingest of a lineage is single-writer, see the README's Limits). Any
# other reason a delta cannot be written (a shrunk edge or episode list, a dropped
# loaded entity, duplicate node ids, an embedding of the wrong width) is an error,
# not a base.
#
# FAILURE. Every refusal and every error from the embedder or the model happens
# before the first store write, so the store is unchanged; the working set may be
# half-edited, and the caller discards it (`ingest_episode` does, since it loads
# its own). Two writes can follow another. A full base is written, then its
# index bootstrap: if the bootstrap fails the base is the head without an index
# (`repair_missing_bootstrap` finishes it). And the change gate's hash is saved
# after the snapshot: if that save fails the episode is stored and the next call
# re-ingests it (entities resolve to themselves and a repeated live edge is not
# added again; only the episode row repeats).
#
# The caller supplies the clock (`EpisodeInput.ts`) and every model; nothing here
# reads the environment or calls a network.
# =============================================================================

from komira_collections.slab import Slab
from komira_kg_format import (
    EntityMention,
    Extraction,
    KgSnapshotStore,
    KgTable,
    SnapshotId,
    content_hash_of,
)
from komira_objectstore.store import CloneableConditionalWriteStore

from .alias_map import AliasMap
from .embedder import Embedder
from .ingest_config import EpisodeInput, IngestConfig
from .ingest_edges import apply_edges
from .ingest_gleaning import run_gleaning
from .ingest_resolve import resolve_entities
from .llm_client import LlmClient
from .rewrite import append_index_bootstrap, base_tables_of
from .working_rows import WorkingEpisode
from .working_set import SnapshotWorkingSet


# The most entities the cross-unit context carries: the highest node ids, which
# are the most recently minted.
comptime CROSS_UNIT_CONTEXT_MAX: Int = 256


def _partition_entities_context(
    ws: SnapshotWorkingSet, partition_id: String
) -> List[EntityMention]:
    """The names and summaries of the partition's entities, at most
    `CROSS_UNIT_CONTEXT_MAX` of them (the highest node ids when there are more),
    for the extract's `already_found`."""
    var idxs = List[Int]()
    for i in range(len(ws.entities)):
        if ws.entities[i].partition_id == partition_id:
            idxs.append(i)
    var out = List[EntityMention]()
    if len(idxs) <= CROSS_UNIT_CONTEXT_MAX:
        for k in range(len(idxs)):
            ref e = ws.entities[idxs[k]]
            out.append(
                EntityMention(String(e.name), String(""), String(e.summary))
            )
        return out^
    var taken = List[Bool](capacity=len(idxs))
    for _ in range(len(idxs)):
        taken.append(False)
    for _ in range(CROSS_UNIT_CONTEXT_MAX):
        var best = -1
        var best_nid = Int64(-1)
        for k in range(len(idxs)):
            if taken[k]:
                continue
            var nid = ws.entities[idxs[k]].nid
            if best < 0 or nid > best_nid:
                best = k
                best_nid = nid
        taken[best] = True
        ref e = ws.entities[idxs[best]]
        out.append(
            EntityMention(String(e.name), String(""), String(e.summary))
        )
    return out^


def _commit_base[
    Store: CloneableConditionalWriteStore
](
    mut store: KgSnapshotStore[Store], ws: SnapshotWorkingSet
) raises -> SnapshotId:
    """Write `ws` as a new base and head, then the index bootstrap a base
    lacks. If the bootstrap fails the base is the head without an index;
    `repair_missing_bootstrap` (run by a later compaction or erasure) adds it."""
    var base = store.write_snapshot(base_tables_of(ws), ws.embedding_dim)
    return append_index_bootstrap(store, ws, base)


def write_extraction[
    Store: CloneableConditionalWriteStore,
    Llm: LlmClient,
    Emb: Embedder,
](
    mut store: KgSnapshotStore[Store],
    mut ws: SnapshotWorkingSet,
    var extraction: Extraction,
    ref llm: Llm,
    ref emb: Emb,
    uuid: String,
    partition_id: String,
    body: String,
    ts: Int64,
    valid_at: Int64,
    cfg: IngestConfig,
    facet: String = String(""),
    facet_source: String = String(""),
) raises -> SnapshotId:
    """The write half of an ingest, over an extraction already made: resolve its
    mentions, apply its triples, append the episode row, persist.

    Parameters:
        Store: The object store (inferred).
        Llm: The model client (inferred); the same-entity and contradiction
            judgments only.
        Emb: The embedder (inferred).

    Args:
        store: The snapshot store; one base or delta is appended.
        ws: The working set the store's head was loaded into (or an empty one
            for an empty lineage). After a successful call it is committed.
        extraction: The mentions and triples to write (consumed).
        llm: The model client.
        emb: The embedder.
        uuid: The episode's external id (its provenance row).
        partition_id: The partition stamped on every row.
        body: The episode text for the provenance row ("" for none).
        ts: The system time of this write.
        valid_at: The episode's event time.
        cfg: The ingest knobs.
        facet: The opaque facet stamped on the episode and on new entities.
        facet_source: The source the facet is attributed to.

    Returns:
        The new head, or the unchanged head if nothing changed.

    Raises:
        As described in the file header: before any store write, if the
        embedder or model raises, an embedding is not the graph's dimension, or
        the set cannot be written as a delta for a reason other than closure
        ambiguity; if the head moved since the start of this call while a full
        base was needed. A full base can fail after its snapshot, when the index
        bootstrap fails.
    """
    var head_id = store.latest_snapshot_id()
    var aliases = AliasMap()
    var resolved = resolve_entities(
        ws,
        extraction.entities,
        llm,
        emb,
        partition_id,
        cfg,
        facet,
        facet_source,
    )
    var mention_names = List[String](capacity=len(extraction.entities))
    for i in range(len(extraction.entities)):
        mention_names.append(String(extraction.entities[i].name))
    apply_edges(
        ws,
        extraction.triples,
        mention_names,
        resolved,
        llm,
        emb,
        partition_id,
        ts,
        valid_at,
        aliases,
        cfg,
        String(""),
        facet,
        facet_source,
    )
    ws.append_episode(
        WorkingEpisode(
            String(uuid),
            String(partition_id),
            String(body),
            ts,
            valid_at,
            String(facet),
        )
    )

    var new_head: SnapshotId
    if head_id < Int64(0):
        new_head = _commit_base(store, ws)
    else:
        # The episode row was just appended, so the set always has a delta; a
        # delta_tables refusal means the delta cannot say it (see the header).
        # Only the closure ambiguity sends the set to a base; any other
        # delta_tables refusal (a shrunk list, a dropped entity, a bad
        # embedding) is an error and writes nothing.
        if not ws.delta_cannot_say_closures():
            new_head = store.append_delta(
                ws.delta_tables(), ws.name_index_delta()
            )
        else:
            if store.latest_snapshot_id() != head_id:
                raise Error(
                    "write_extraction: the head moved from "
                    + String(head_id)
                    + " while a full base was needed; reload the working set"
                )
            new_head = _commit_base(store, ws)
    ws.mark_committed()
    return new_head


def ingest_episode_into[
    Store: CloneableConditionalWriteStore,
    Llm: LlmClient,
    Emb: Embedder,
](
    mut store: KgSnapshotStore[Store],
    mut ws: SnapshotWorkingSet,
    episode: EpisodeInput,
    ref llm: Llm,
    ref emb: Emb,
    cfg: IngestConfig,
) raises -> SnapshotId:
    """Ingest one episode into the graph, through a working set the caller
    holds (loaded from the store's head, or empty for an empty lineage).

    An episode whose body hashes to the stored hash of its
    `(partition_id, uuid)` is skipped: the head is returned, no model is called
    and nothing is written. Otherwise the episode is extracted, resolved,
    applied and stored (see the file header), and its hash is recorded. A
    different `uuid` with the same body is a different source and is ingested;
    its entities resolve to the existing ones and its repeated live edges are
    not added again.

    Parameters:
        Store: The object store (inferred).
        Llm: The model client (inferred).
        Emb: The embedder (inferred).

    Args:
        store: The snapshot store.
        ws: The working set; committed after a successful write, to be discarded
            after an error.
        episode: The episode.
        llm: The model client (`extract`, `judge_same_entity`,
            `judge_contradiction`).
        emb: The embedder; its dimension must be the set's.
        cfg: The ingest knobs.

    Returns:
        The new head, or the current head if the episode was unchanged.

    Raises:
        If `cfg` is invalid, the embedder's dimension is not the set's, the
        model or embedder raises, an embedding is not the graph's dimension, or
        the store fails. See the file header for what an error leaves behind.
    """
    cfg.check()
    if emb.dimension() != ws.embedding_dim:
        raise Error(
            "ingest_episode: the embedder's dimension is "
            + String(emb.dimension())
            + " but the graph's is "
            + String(ws.embedding_dim)
        )
    var content_hash = content_hash_of(episode.body)
    var prior = store.fingerprint_lookup(episode.partition_id, episode.uuid)
    if len(prior.as_bytes()) > 0 and prior == content_hash:
        return store.latest_snapshot_id()

    var seed = List[EntityMention]()
    if cfg.cross_unit_context:
        seed = _partition_entities_context(ws, episode.partition_id)
    var extraction = run_gleaning(llm, episode.body, cfg.max_gleanings, seed)
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
    )
    store.fingerprint_patch_save(
        String(episode.partition_id),
        String(episode.uuid),
        content_hash^,
        String(""),
    )
    return new_head


def ingest_episode[
    Store: CloneableConditionalWriteStore,
    Llm: LlmClient,
    Emb: Embedder,
](
    mut store: KgSnapshotStore[Store],
    episode: EpisodeInput,
    ref llm: Llm,
    ref emb: Emb,
    cfg: IngestConfig,
) raises -> SnapshotId:
    """Ingest one episode, loading the working set from the store's head (an
    empty set of the embedder's dimension for an empty lineage). A set loaded
    from a head takes the manifest's dimension, which the embedder must match.

    Parameters:
        Store: The object store (inferred).
        Llm: The model client (inferred).
        Emb: The embedder (inferred).

    Args:
        store: The snapshot store.
        episode: The episode.
        llm: The model client.
        emb: The embedder.
        cfg: The ingest knobs.

    Returns:
        The new head, or the current head if the episode was unchanged.

    Raises:
        As `ingest_episode_into`, and if the head cannot be loaded. After an
        error the store is unchanged, except that a full base whose index
        bootstrap failed is the head without an index (the working set is this
        call's own).
    """
    if store.latest_snapshot_id() < Int64(0):
        var empty = SnapshotWorkingSet(emb.dimension())
        return ingest_episode_into(store, empty, episode, llm, emb, cfg)
    var ws = SnapshotWorkingSet.load_latest(store)
    return ingest_episode_into(store, ws, episode, llm, emb, cfg)
