# =============================================================================
# ingest_source_diff -- what a source that replaces its facts changes.
# =============================================================================
#
# A structured ingest that names its source (an opaque id, unique within a
# partition) states the whole set of facts that source holds. Two steps follow
# from that:
#
#   * the per-symbol diff (`split_incremental`): a triple that repeats an edge the
#     source already holds, unexpired, between entities that already exist, is
#     unchanged, and is left alone: its entities are not embedded or resolved
#     again. Only the changed triples, with the mentions they need and the
#     mentions of entities that do not exist yet, go on to be applied.
#   * the removal (`retire_absent`): an edge the source held before and no triple
#     of this ingest states (changed or not) is closed, never deleted. Its end is
#     the ingest's system time (when it was open), and its expiry the same.
#
# SCOPE. A source id is unique only within a partition (the change gate keys on
# both), so both steps see only the edges of the ingest's partition: an edge
# belongs to the partition of its source entity. An empty partition id sees all.
# Another source's identical edge is another row and is never touched, and an
# entity is never closed by a source ceasing to mention it.
# =============================================================================

from komira_kg_format import EntityMention, Extraction, TS_OPEN_SENTINEL, Triple

from .ingest_edges import AssertedEdge
from .ingest_resolve import existing_nid_for_name
from .working_set import SnapshotWorkingSet


def source_edge_indices(
    ws: SnapshotWorkingSet, source: String, partition_id: String
) -> List[Int]:
    """The positions of the edges `source` holds in the partition: attributed to
    it, not expired, and starting at an entity of `partition_id` (any entity when
    `partition_id` is empty).

    Args:
        ws: The working set.
        source: The source id.
        partition_id: The partition, or "" for all.

    Returns:
        Ascending positions into `ws.edges`.
    """
    var in_partition = Dict[Int64, Bool]()
    for i in range(len(ws.entities)):
        if ws.entities[i].partition_id == partition_id:
            in_partition[ws.entities[i].nid] = True
    var scoped = len(partition_id.as_bytes()) > 0
    var out = List[Int]()
    for i in range(len(ws.edges)):
        ref e = ws.edges[i]
        if e.source != source or e.expired_at != TS_OPEN_SENTINEL:
            continue
        if scoped and e.src_nid not in in_partition:
            continue
        out.append(i)
    return out^


def _name_in(names: List[String], name: String) -> Bool:
    for i in range(len(names)):
        if names[i] == name:
            return True
    return False


def split_incremental(
    ws: SnapshotWorkingSet,
    var extraction: Extraction,
    prior: List[Int],
    partition_id: String,
    episode_valid_at: Int64,
    mut unchanged: List[AssertedEdge],
) -> Extraction:
    """Split an extraction into what must be applied and what the source already
    holds.

    A triple is unchanged when both endpoint names already name an entity of the
    partition (an exact normalized-name lookup, no embedding) and one of the
    source's edges in `prior` is the same assertion (`AssertedEdge.matches`:
    endpoints, fact and interval). Each unchanged triple is appended to
    `unchanged`. The returned extraction holds the changed triples, and the
    mentions that a changed triple names or that name no existing entity.

    Args:
        ws: The working set.
        extraction: The full extraction (consumed).
        prior: The source's edges before this ingest (`source_edge_indices`).
        partition_id: The partition.
        episode_valid_at: The `valid_at` an undated triple takes.
        unchanged: Appended to.

    Returns:
        The reduced extraction to apply.
    """
    var changed = List[Triple]()
    var needed = List[String]()
    for ti in range(len(extraction.triples)):
        ref t = extraction.triples[ti]
        var src_nid = existing_nid_for_name(ws, t.subject_name, partition_id)
        var dst_nid = existing_nid_for_name(ws, t.object_name, partition_id)
        var valid_at = t.valid_at
        if valid_at == TS_OPEN_SENTINEL:
            valid_at = episode_valid_at
        var is_unchanged = False
        if src_nid >= Int64(0) and dst_nid >= Int64(0):
            var identity = AssertedEdge(
                src_nid, dst_nid, String(t.fact), valid_at, t.invalid_at
            )
            for k in range(len(prior)):
                if identity.matches(ws.edges[prior[k]]):
                    is_unchanged = True
                    break
            if is_unchanged:
                unchanged.append(identity^)
        if not is_unchanged:
            changed.append(t.copy())
            if not _name_in(needed, t.subject_name):
                needed.append(String(t.subject_name))
            if not _name_in(needed, t.object_name):
                needed.append(String(t.object_name))
    var mentions = List[EntityMention]()
    for ei in range(len(extraction.entities)):
        ref m = extraction.entities[ei]
        if _name_in(needed, m.name) or (
            existing_nid_for_name(ws, m.name, partition_id) < Int64(0)
        ):
            mentions.append(m.copy())
    return Extraction(mentions^, changed^)


def retire_absent(
    mut ws: SnapshotWorkingSet,
    prior: List[Int],
    asserted: List[AssertedEdge],
    unchanged: List[AssertedEdge],
    ts: Int64,
):
    """Close each of the source's earlier edges that nothing in this ingest
    states.

    An edge in `prior` is kept if it is still unexpired (a contradiction in this
    same ingest may have closed it already) and some entry of `asserted` or
    `unchanged` is the same assertion. Any other is closed: an open edge ends at
    `ts` (not before its own start), and its expiry is `ts`; an edge that had
    already ended keeps its end and is only expired.

    Args:
        ws: The working set; edges are closed in place.
        prior: The source's edges before the ingest (`source_edge_indices`).
        asserted: What the applied triples asserted.
        unchanged: What the unchanged triples asserted.
        ts: The system time of this write.
    """
    for k in range(len(prior)):
        var at = prior[k]
        if ws.edges[at].expired_at != TS_OPEN_SENTINEL:
            continue
        var stated = False
        for a in range(len(asserted)):
            if asserted[a].matches(ws.edges[at]):
                stated = True
                break
        if not stated:
            for u in range(len(unchanged)):
                if unchanged[u].matches(ws.edges[at]):
                    stated = True
                    break
        if stated:
            continue
        if ws.edges[at].invalid_at == TS_OPEN_SENTINEL:
            ws.edges[at].invalid_at = max(ts, ws.edges[at].valid_at)
        ws.edges[at].expired_at = ts
