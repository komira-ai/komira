# =============================================================================
# working_set -- the in-memory mutable graph state of one ingest: load a
#   snapshot, apply changes, write the tables back.
# =============================================================================
#
# `SnapshotWorkingSet` holds three lists of value rows (entities, edges,
# episodes) and the node-id high-water mark. A writer
#
#   1. loads the live graph (`load_latest`, `load_merged`, `load_from`), or starts
#      an empty one for the first ingest of a lineage;
#   2. mints node ids (`next_nid`), adds entities, adds edges, stamps
#      supersessions in place and appends episodes;
#   3. writes the result back: `to_tables` is the whole graph as a base snapshot,
#      `delta_tables` only what changed since the load, with `name_index_delta`
#      for the exact-name index that rides the same delta.
#
# EMBEDDING DIMENSION. The set carries the graph's dimension. A set made empty
# is given one (there is no default); a loaded set takes the manifest's. Every
# embedding read from storage must match it, and every embedding added or
# written is held to it, so the set never holds vectors of two sizes.
#
# THE KEYSTONE. Merging a base with its deltas (`load_merged`) gives the rows a
# full rewrite of the same facts would hold. The merge appends a delta's
# episodes, upserts its entities by node id (the later delta wins), appends its
# edges, and stamps the end times of its tombstoned edges onto the matching
# earlier edge, matched by `(src_nid, dst_nid, created_at)`. A tombstone that
# matches no edge is an error. If several edges share that key, the tombstone
# applies to the one that is still open, and is refused as ambiguous unless
# exactly one is.
#
# THE KEY LIMIT. A tombstone carries no more than that key, so a delta cannot
# close one of two open edges that share `(src_nid, dst_nid, created_at)`:
# `delta_tables` refuses such a set, and the writer writes a base with
# `to_tables` instead (a base carries every edge's end times in its own row, so
# it is exact for any set).
#
# THE DIFF. A load records the loaded state. `delta_tables` then emits the
# entities that are new (node id not loaded) or changed (the row differs from the
# loaded one), the edges appended since, a tombstone for each loaded edge whose
# end times changed, and the episodes appended since. It reads the rows by
# position, so the first `len(edges)` loaded edges and episodes must still be
# where they were: it refuses a set that has shrunk below its load, and a set
# from which a loaded entity was removed, because a delta cannot say a removal
# (write a full snapshot with `to_tables` instead). A writer that keeps its set
# after appending its own delta calls `mark_committed`, which makes the set's
# current state the new loaded state.
#
# No clock and no environment are read: every time is a field of a row the
# caller supplies. Nothing here touches a file system.
# =============================================================================

from komira_arrow.record_batch import RecordBatch
from komira_collections.slab import Slab
from komira_kg_format import (
    ChainView,
    KgNameIndexBody,
    KgSnapshotStore,
    KgTable,
    SCHEMA_VERSION_EDGES,
    SCHEMA_VERSION_ENTITIES,
    SCHEMA_VERSION_ENTITIES_EMBEDDING,
    SCHEMA_VERSION_EPISODES,
    SnapshotView,
    TS_OPEN_SENTINEL,
    pack_embedding,
    unpack_embedding_checked,
)
from komira_objectstore.store import CloneableConditionalWriteStore

from .bitemporal import WorkingEdge
from .name_similarity import normalize_name
from .working_codec import (
    EdgeClosure,
    TABLE_EDGES,
    TABLE_EDGES_TOMBSTONE,
    TABLE_ENTITIES,
    TABLE_ENTITIES_EMBEDDING,
    TABLE_EPISODES,
    build_edges_batch,
    build_embedding_projection_batch,
    build_entities_batch,
    build_episodes_batch,
    build_tombstone_batch,
    check_embedding,
    decode_edge_closures,
    decode_edges,
    decode_entities,
    decode_episodes,
    read_base_table,
    read_delta_table,
)
from .working_rows import WorkingEntity, WorkingEpisode


def _entity_signature(e: WorkingEntity) -> String:
    """A canonical, boundary-safe serialization of an entity row, for telling a
    loaded row from an edited one. The embedding is compared as it is stored
    (narrowed to f32)."""
    var out = String()
    out += String(e.nid)
    out += ":"
    var fields = List[String]()
    fields.append(e.uuid)
    fields.append(e.partition_id)
    fields.append(e.name)
    fields.append(e.summary)
    fields.append(e.attrs)
    fields.append(pack_embedding(e.name_embedding))
    for i in range(len(fields)):
        out += String(len(fields[i].as_bytes()))
        out += ":"
        out += fields[i]
    return out^


struct PartitionDrop(Copyable, Movable):
    """What `SnapshotWorkingSet.load_merged_without_partition` left out.

    Fields:
        entities: Distinct node ids of the partition's entities.
        edges: Edges with one of those entities as an endpoint.
        episodes: Episodes of the partition.
        tombstones: Tombstones of such edges.
    """

    var entities: Int
    var edges: Int
    var episodes: Int
    var tombstones: Int

    def __init__(out self):
        """Nothing left out."""
        self.entities = 0
        self.edges = 0
        self.episodes = 0
        self.tombstones = 0

    def total(self) -> Int:
        """Every row left out, tombstones included."""
        return self.entities + self.edges + self.episodes + self.tombstones


struct SnapshotWorkingSet(Movable):
    """The in-memory mutable graph state for one ingest.

    The three row lists are public: a writer reads and edits them in place. The
    node-id high-water mark and the loaded-state record are private.
    """

    var entities: List[WorkingEntity]
    var edges: List[WorkingEdge]
    var episodes: List[WorkingEpisode]
    var embedding_dim: Int
    var _high_water: Int64
    # The state at the end of the last load (empty for a fresh set).
    var _base_entities: Dict[Int64, String]
    var _base_edge_invalid: List[Int64]
    var _base_edge_expired: List[Int64]
    var _base_edge_count: Int
    var _base_episode_count: Int

    def __init__(out self, embedding_dim: Int) raises:
        """An empty working set (the first ingest of a lineage).

        Args:
            embedding_dim: The components of every embedding in the graph; more
                than zero. There is no default.

        Raises:
            If `embedding_dim` is not positive.
        """
        if embedding_dim <= 0:
            raise Error(
                "SnapshotWorkingSet: embedding dimension must be positive, got "
                + String(embedding_dim)
            )
        self.entities = List[WorkingEntity]()
        self.edges = List[WorkingEdge]()
        self.episodes = List[WorkingEpisode]()
        self.embedding_dim = embedding_dim
        self._high_water = Int64(0)
        self._base_entities = Dict[Int64, String]()
        self._base_edge_invalid = List[Int64]()
        self._base_edge_expired = List[Int64]()
        self._base_edge_count = 0
        self._base_episode_count = 0

    # -------------------------------------------------------------------------
    # Loading.
    # -------------------------------------------------------------------------

    @staticmethod
    def load_from[
        Store: CloneableConditionalWriteStore
    ](view: SnapshotView[Store]) raises -> SnapshotWorkingSet:
        """Load the working set from a resolved base snapshot (no deltas).

        A table the snapshot omits loads as empty. The dimension is the
        manifest's.

        Raises:
            If a table is newer than this build reads, is unreadable or
            malformed, or holds an embedding of another length than the
            manifest's.
        """
        var ws = SnapshotWorkingSet(view.embedding_dim())
        ws._load_base(view)
        ws._finish_load()
        return ws^

    @staticmethod
    def load_latest[
        Store: CloneableConditionalWriteStore
    ](store: KgSnapshotStore[Store]) raises -> SnapshotWorkingSet:
        """Load the live graph from the store's head: the base merged with its
        deltas. A base-only head is a chain of no deltas."""
        return SnapshotWorkingSet.load_merged(store.open_latest_chain())

    @staticmethod
    def load_merged[
        Store: CloneableConditionalWriteStore
    ](chain: ChainView[Store]) raises -> SnapshotWorkingSet:
        """Reconstruct the live graph from a resolved chain: the base, then each
        delta in apply order (see the file header for the merge rules).

        Raises:
            As `load_from`, and if a delta's table is malformed, repeats a node
            id in its entities, or a tombstone matches no edge.
        """
        var gone = Dict[Int64, Bool]()
        var dropped = PartitionDrop()
        return SnapshotWorkingSet._merge_chain(chain, False, String(), gone, dropped)

    @staticmethod
    def load_merged_without_partition[
        Store: CloneableConditionalWriteStore
    ](
        chain: ChainView[Store],
        partition_id: String,
        mut gone: Dict[Int64, Bool],
        mut dropped: PartitionDrop,
    ) raises -> SnapshotWorkingSet:
        """`load_merged`, leaving out every row of `partition_id`, wherever the
        chain holds it: its entities (base or delta), its episodes, every edge
        with one of its entities as an endpoint, and every tombstone for such
        an edge (a tombstone of an edge that is not loaded is not an error
        here). The result is what `erase_partition` leaves of the merged set,
        but it is built from a chain whose deltas may speak of rows the base no
        longer holds, which `load_merged` refuses.

        Args:
            chain: The resolved chain.
            partition_id: The partition to leave out.
            gone: Node ids already known to be erased (a node id the chain
                still speaks of is dropped); the partition's node ids found
                here are added.
            dropped: Counts what was left out; added to, not reset.

        Raises:
            As `load_merged`, except for the tombstones left out.
        """
        return SnapshotWorkingSet._merge_chain(
            chain, True, partition_id, gone, dropped
        )

    @staticmethod
    def _merge_chain[
        Store: CloneableConditionalWriteStore
    ](
        chain: ChainView[Store],
        drop: Bool,
        partition_id: String,
        mut gone: Dict[Int64, Bool],
        mut dropped: PartitionDrop,
    ) raises -> SnapshotWorkingSet:
        var ws = SnapshotWorkingSet(chain.base.embedding_dim())
        ws._load_base(chain.base)
        # The entities of every delta, decoded once: with a partition to leave
        # out, its node ids must be known before any edge is applied.
        var delta_entities = List[List[WorkingEntity]]()
        for di in range(chain.num_deltas()):
            var rows = List[WorkingEntity]()
            if chain.deltas[di].has_table(TABLE_ENTITIES):
                rows = decode_entities(
                    read_delta_table(
                        chain, di, TABLE_ENTITIES, SCHEMA_VERSION_ENTITIES
                    ),
                    ws.embedding_dim,
                )
            delta_entities.append(rows^)
        # A node id counts once in `dropped.entities`, however often the chain
        # speaks of it.
        var counted = Dict[Int64, Bool]()
        if drop:
            for i in range(len(ws.entities)):
                if ws.entities[i].partition_id == partition_id:
                    gone[ws.entities[i].nid] = True
            for di in range(len(delta_entities)):
                for i in range(len(delta_entities[di])):
                    if delta_entities[di][i].partition_id == partition_id:
                        gone[delta_entities[di][i].nid] = True
            ws._drop_base_rows(partition_id, gone, counted, dropped)
        # Node id -> position in `entities`, kept while deltas are applied.
        var at = Dict[Int64, Int]()
        for i in range(len(ws.entities)):
            at[ws.entities[i].nid] = i
        for di in range(chain.num_deltas()):
            ref dbody = chain.deltas[di]
            if dbody.has_table(TABLE_EPISODES):
                var batch = read_delta_table(
                    chain, di, TABLE_EPISODES, SCHEMA_VERSION_EPISODES
                )
                var rows = decode_episodes(batch)
                for i in range(len(rows)):
                    if drop and rows[i].partition_id == partition_id:
                        dropped.episodes += 1
                    else:
                        ws.episodes.append(rows[i].copy())
            var seen = Dict[Int64, Bool]()
            ref erows = delta_entities[di]
            for i in range(len(erows)):
                var nid = erows[i].nid
                if nid in seen:
                    raise Error(
                        "delta "
                        + String(di)
                        + ": entities table repeats node id "
                        + String(nid)
                    )
                seen[nid] = True
                if drop and nid in gone:
                    if nid not in counted:
                        counted[nid] = True
                        dropped.entities += 1
                    continue
                if nid in at:
                    ws.entities[at[nid]] = erows[i].copy()
                else:
                    at[nid] = len(ws.entities)
                    ws.entities.append(erows[i].copy())
            if dbody.has_table(TABLE_EDGES):
                var batch = read_delta_table(
                    chain, di, TABLE_EDGES, SCHEMA_VERSION_EDGES
                )
                var rows = decode_edges(batch)
                for i in range(len(rows)):
                    if drop and (
                        rows[i].src_nid in gone or rows[i].dst_nid in gone
                    ):
                        dropped.edges += 1
                    else:
                        ws.edges.append(rows[i].copy())
            if dbody.has_table(TABLE_EDGES_TOMBSTONE):
                var batch = read_delta_table(
                    chain, di, TABLE_EDGES_TOMBSTONE, SCHEMA_VERSION_EDGES
                )
                var closures = decode_edge_closures(batch)
                if drop:
                    var kept = List[EdgeClosure]()
                    for r in range(len(closures)):
                        if (
                            closures[r].src_nid in gone
                            or closures[r].dst_nid in gone
                        ):
                            dropped.tombstones += 1
                        else:
                            kept.append(closures[r].copy())
                    closures = kept^
                ws._apply_closures(closures, di)
        ws._finish_load()
        return ws^

    def _drop_base_rows(
        mut self,
        partition_id: String,
        gone: Dict[Int64, Bool],
        mut counted: Dict[Int64, Bool],
        mut dropped: PartitionDrop,
    ):
        """Leave the base rows of the partition (and of the node ids in `gone`)
        out of the set."""
        var entities = List[WorkingEntity]()
        for i in range(len(self.entities)):
            var nid = self.entities[i].nid
            if nid in gone:
                if nid not in counted:
                    counted[nid] = True
                    dropped.entities += 1
            else:
                entities.append(self.entities[i].copy())
        var edges = List[WorkingEdge]()
        for i in range(len(self.edges)):
            ref e = self.edges[i]
            if e.src_nid in gone or e.dst_nid in gone:
                dropped.edges += 1
            else:
                edges.append(e.copy())
        var episodes = List[WorkingEpisode]()
        for i in range(len(self.episodes)):
            if self.episodes[i].partition_id == partition_id:
                dropped.episodes += 1
            else:
                episodes.append(self.episodes[i].copy())
        self.entities = entities^
        self.edges = edges^
        self.episodes = episodes^

    def _load_base[
        Store: CloneableConditionalWriteStore
    ](mut self, view: SnapshotView[Store]) raises:
        if view.has_table(TABLE_ENTITIES):
            var batch = read_base_table(
                view, TABLE_ENTITIES, SCHEMA_VERSION_ENTITIES
            )
            self.entities = decode_entities(batch, self.embedding_dim)
            var seen = Dict[Int64, Bool]()
            for i in range(len(self.entities)):
                var nid = self.entities[i].nid
                if nid in seen:
                    raise Error(
                        "table entities: repeats node id " + String(nid)
                    )
                seen[nid] = True
        if view.has_table(TABLE_EDGES):
            var batch = read_base_table(view, TABLE_EDGES, SCHEMA_VERSION_EDGES)
            self.edges = decode_edges(batch)
        if view.has_table(TABLE_EPISODES):
            var batch = read_base_table(
                view, TABLE_EPISODES, SCHEMA_VERSION_EPISODES
            )
            self.episodes = decode_episodes(batch)

    def _apply_closures(
        mut self, closures: List[EdgeClosure], di: Int
    ) raises:
        # Closures apply in order, and each sees the end times the earlier ones
        # set, so a key is looked up afresh for every closure.
        for r in range(len(closures)):
            ref c = closures[r]
            var found = -1
            var count = 0
            var open_found = -1
            var open_count = 0
            for j in range(len(self.edges)):
                ref ed = self.edges[j]
                if (
                    ed.src_nid != c.src_nid
                    or ed.dst_nid != c.dst_nid
                    or ed.created_at != c.created_at
                ):
                    continue
                count += 1
                found = j
                if ed.is_open():
                    open_count += 1
                    open_found = j
            var label = (
                "delta "
                + String(di)
                + ": tombstone for edge ("
                + String(c.src_nid)
                + ", "
                + String(c.dst_nid)
                + ", "
                + String(c.created_at)
            )
            if count == 0:
                raise Error(label + ") matches no edge")
            var target = found
            if count > 1:
                # Several edges share the key: the tombstone is only
                # unambiguous when exactly one of them is still open.
                if open_count != 1:
                    raise Error(
                        label
                        + ") is ambiguous: "
                        + String(count)
                        + " edges share the key and "
                        + String(open_count)
                        + " are open"
                    )
                target = open_found
            ref ed = self.edges[target]
            ed.invalid_at = c.invalid_at
            ed.expired_at = c.expired_at

    def _finish_load(mut self):
        var hw = Int64(0)
        self._base_entities = Dict[Int64, String]()
        for i in range(len(self.entities)):
            var nid = self.entities[i].nid
            # decode_entities keeps nid below Int64.MAX, so nid + 1 cannot wrap.
            if nid >= hw:
                hw = nid + Int64(1)
            self._base_entities[nid] = _entity_signature(self.entities[i])
        self._high_water = hw
        self._base_edge_invalid = List[Int64]()
        self._base_edge_expired = List[Int64]()
        for i in range(len(self.edges)):
            self._base_edge_invalid.append(self.edges[i].invalid_at)
            self._base_edge_expired.append(self.edges[i].expired_at)
        self._base_edge_count = len(self.edges)
        self._base_episode_count = len(self.episodes)

    # -------------------------------------------------------------------------
    # Mutation.
    # -------------------------------------------------------------------------

    def next_nid(mut self) raises -> Int64:
        """Mint a fresh node id: one more than the largest id ever held, never
        reused (an erasure does not lower it).

        Raises:
            If the id space is exhausted.
        """
        if self._high_water == Int64.MAX:
            raise Error("SnapshotWorkingSet.next_nid: node ids exhausted")
        var nid = self._high_water
        self._high_water = self._high_water + Int64(1)
        return nid

    def add_entity(mut self, var entity: WorkingEntity) raises:
        """Append a new entity. The id is normally one `next_nid` minted; a
        larger one raises the high-water mark past it.

        Raises:
            If the id is outside `[0, Int64.MAX)`, or the embedding is not
            `embedding_dim` finite components.
        """
        if entity.nid < 0 or entity.nid == Int64.MAX:
            raise Error(
                "SnapshotWorkingSet.add_entity: node id "
                + String(entity.nid)
                + " is out of range"
            )
        check_embedding(
            entity.name_embedding, self.embedding_dim, "add_entity"
        )
        if entity.nid >= self._high_water:
            self._high_water = entity.nid + Int64(1)
        self.entities.append(entity^)

    def add_edge(mut self, var edge: WorkingEdge):
        """Append a new edge."""
        self.edges.append(edge^)

    def append_episode(mut self, var episode: WorkingEpisode):
        """Append an episode row (append-only provenance)."""
        self.episodes.append(episode^)

    def num_entities(self) -> Int:
        """The number of entities."""
        return len(self.entities)

    def num_edges(self) -> Int:
        """The number of edges."""
        return len(self.edges)

    def num_episodes(self) -> Int:
        """The number of episodes."""
        return len(self.episodes)

    def entity_index_of_nid(self, nid: Int64) -> Int:
        """The position of the entity with node id `nid` (a linear scan), or -1.
        """
        for i in range(len(self.entities)):
            if self.entities[i].nid == nid:
                return i
        return -1

    # -------------------------------------------------------------------------
    # The diff against the load.
    # -------------------------------------------------------------------------

    def added_entity_indices(self) -> List[Int]:
        """Positions of the entities whose node id was not loaded."""
        var out = List[Int]()
        for i in range(len(self.entities)):
            if self.entities[i].nid not in self._base_entities:
                out.append(i)
        return out^

    def edited_entity_indices(self) -> List[Int]:
        """Positions of loaded entities whose row now differs from the loaded
        row."""
        var out = List[Int]()
        for i in range(len(self.entities)):
            ref e = self.entities[i]
            if e.nid in self._base_entities:
                if self._base_entities.get(e.nid, String("")) != _entity_signature(e):
                    out.append(i)
        return out^

    def _changed_entity_indices(self) -> List[Int]:
        """Added and edited entities, in position order."""
        var out = List[Int]()
        for i in range(len(self.entities)):
            ref e = self.entities[i]
            if e.nid not in self._base_entities:
                out.append(i)
            elif self._base_entities.get(e.nid, String("")) != _entity_signature(e):
                out.append(i)
        return out^

    def tombstone_edge_indices(self) -> List[Int]:
        """Positions of loaded edges whose end times changed since the load."""
        var out = List[Int]()
        var nb = self._base_edge_count
        if nb > len(self.edges):
            nb = len(self.edges)
        for i in range(nb):
            ref e = self.edges[i]
            if (
                e.invalid_at != self._base_edge_invalid[i]
                or e.expired_at != self._base_edge_expired[i]
            ):
                out.append(i)
        return out^

    def has_delta(self) -> Bool:
        """True iff anything changed since the load: an entity added or
        edited, an edge or episode appended, or an edge closed."""
        if len(self._changed_entity_indices()) > 0:
            return True
        if len(self.edges) > self._base_edge_count:
            return True
        if len(self.episodes) > self._base_episode_count:
            return True
        return len(self.tombstone_edge_indices()) > 0

    def mark_committed(mut self) raises:
        """Declare that the set's current state is now what the store holds, so
        the next `delta_tables` is relative to it.

        A resident set that keeps going after its own delta was appended calls
        this. The embeddings of the entities added or edited since the load are
        first narrowed to f32 exactly as the table cell stores them, so the
        resident vectors equal the ones a reload would give. The node-id
        high-water mark is kept (it never goes down).

        Raises:
            If an embedding is not `embedding_dim` finite components.
        """
        var changed = self._changed_entity_indices()
        for k in range(len(changed)):
            ref e = self.entities[changed[k]]
            check_embedding(e.name_embedding, self.embedding_dim, "mark_committed")
            var packed = pack_embedding(e.name_embedding)
            e.name_embedding = unpack_embedding_checked(
                packed.as_bytes(), self.embedding_dim
            )
        var kept = self._high_water
        self._finish_load()
        if kept > self._high_water:
            self._high_water = kept

    def name_index_delta(self) raises -> KgNameIndexBody:
        """The `{normalize_name(name) -> nid}` entries for the entities added or
        edited since the load; they ride the same delta append, so the next
        ingest's exact-name match resolves them without loading the base."""
        var idx = KgNameIndexBody()
        var changed = self._changed_entity_indices()
        for k in range(len(changed)):
            ref e = self.entities[changed[k]]
            idx.add(normalize_name(e.name), e.nid)
        return idx^

    def full_name_index(self) raises -> KgNameIndexBody:
        """The name index of every entity (not only the changed ones), for the
        bootstrap delta of a compacted base."""
        var idx = KgNameIndexBody()
        for i in range(len(self.entities)):
            ref e = self.entities[i]
            idx.add(normalize_name(e.name), e.nid)
        return idx^

    def full_embedding_projection(self) raises -> RecordBatch:
        """The `entities_embedding` projection of every entity, for the
        bootstrap delta of a compacted base."""
        return build_embedding_projection_batch(
            self.entities, self._all(len(self.entities)), self.embedding_dim
        )

    # -------------------------------------------------------------------------
    # Writing.
    # -------------------------------------------------------------------------

    def _all(self, n: Int) -> List[Int]:
        var out = List[Int]()
        for i in range(n):
            out.append(i)
        return out^

    def _check_unique_nids(self) raises:
        var seen = Dict[Int64, Bool]()
        for i in range(len(self.entities)):
            var nid = self.entities[i].nid
            if nid in seen:
                raise Error(
                    "SnapshotWorkingSet: two entities share node id "
                    + String(nid)
                )
            seen[nid] = True

    def _is_open_when_delta_applies(self, i: Int) -> Bool:
        # A loaded edge is as it was loaded; an edge appended since is written
        # in its current state by the same delta, before the tombstones apply.
        if i < self._base_edge_count and i < len(self._base_edge_invalid):
            return self._base_edge_invalid[i] == TS_OPEN_SENTINEL
        return self.edges[i].is_open()

    def _ambiguous_closure(self, closed: List[Int]) raises -> Int:
        # The first edge in `closed` that the loader could not tell from another
        # edge of its key when the tombstone applies, or -1.
        if len(closed) == 0:
            return -1
        var group = Dict[String, List[Int]]()
        for j in range(len(self.edges)):
            ref ed = self.edges[j]
            var key = _edge_key(ed.src_nid, ed.dst_nid, ed.created_at)
            if key not in group:
                group[key] = List[Int]()
            group[key].append(j)
        for k in range(len(closed)):
            var i = closed[k]
            ref ed = self.edges[i]
            ref members = group[_edge_key(ed.src_nid, ed.dst_nid, ed.created_at)]
            if len(members) == 1:
                continue
            # The loader applies the tombstone to the one open edge of the key;
            # that must be this edge.
            var open_count = 0
            for m in range(len(members)):
                if self._is_open_when_delta_applies(members[m]):
                    open_count += 1
            if open_count == 1 and self._is_open_when_delta_applies(i):
                continue
            return i
        return -1

    def delta_cannot_say_closures(self) raises -> Bool:
        """True iff an edge closed since the load shares its
        `(src_nid, dst_nid, created_at)` key with another edge that a tombstone
        could not tell it from, so `delta_tables` would refuse for that reason
        and only a full base can carry the set. It says nothing about any other
        reason `delta_tables` refuses (a shrunk list, a dropped entity, a bad
        embedding); those are errors, not a case for a base."""
        return self._ambiguous_closure(self.tombstone_edge_indices()) >= 0

    def _check_closures_unambiguous(self, closed: List[Int]) raises:
        var i = self._ambiguous_closure(closed)
        if i < 0:
            return
        ref ed = self.edges[i]
        var shared = 0
        for j in range(len(self.edges)):
            if (
                self.edges[j].src_nid == ed.src_nid
                and self.edges[j].dst_nid == ed.dst_nid
                and self.edges[j].created_at == ed.created_at
            ):
                shared += 1
        raise Error(
            "SnapshotWorkingSet.delta_tables: edge ("
            + String(ed.src_nid)
            + ", "
            + String(ed.dst_nid)
            + ", "
            + String(ed.created_at)
            + ") shares its key with "
            + String(shared - 1)
            + " other edge(s), so a tombstone cannot say which one to"
            " close; write a full base with to_tables instead"
        )

    def _check_no_loaded_entity_dropped(self) raises:
        # A delta adds and changes entities but cannot remove one, so a set that
        # lost a loaded entity (an erasure) would get it back on reload.
        var present = Dict[Int64, Bool]()
        for i in range(len(self.entities)):
            present[self.entities[i].nid] = True
        for nid in self._base_entities.keys():
            if nid not in present:
                raise Error(
                    "SnapshotWorkingSet.delta_tables: loaded entity "
                    + String(nid)
                    + " was removed since the load, which a delta cannot say;"
                    " write a full snapshot with to_tables instead"
                )

    def to_tables(self) raises -> Slab[KgTable]:
        """The whole graph as tables for `write_snapshot`. Only non-empty tables
        are emitted. The dimension to record in the manifest is
        `embedding_dim`.

        Raises:
            If two entities share a node id or an embedding is not
            `embedding_dim` finite components.
        """
        self._check_unique_nids()
        var tables = Slab[KgTable]()
        if len(self.entities) > 0:
            tables.append(
                KgTable(
                    String(TABLE_ENTITIES),
                    build_entities_batch(
                        self.entities,
                        self._all(len(self.entities)),
                        self.embedding_dim,
                    ),
                    SCHEMA_VERSION_ENTITIES,
                )
            )
        if len(self.edges) > 0:
            tables.append(
                KgTable(
                    String(TABLE_EDGES),
                    build_edges_batch(
                        self.edges, self._all(len(self.edges)), self.entities
                    ),
                    SCHEMA_VERSION_EDGES,
                )
            )
        if len(self.episodes) > 0:
            tables.append(
                KgTable(
                    String(TABLE_EPISODES),
                    build_episodes_batch(
                        self.episodes, self._all(len(self.episodes))
                    ),
                    SCHEMA_VERSION_EPISODES,
                )
            )
        return tables^

    def delta_tables(self) raises -> Slab[KgTable]:
        """Only what changed since the load, as delta tables for
        `append_delta`: an `entities` table of the added and edited entities
        with their `entities_embedding` projection, an `edges` table of the
        appended edges, an `edges_tombstone` table of the closed ones and an
        `episodes` table of the appended ones. An empty slab means nothing
        changed.

        Raises:
            If the edges or episodes shrank below their loaded count, two
            entities share a node id, an embedding is not `embedding_dim`
            finite components, or an edge to be closed shares its
            `(src_nid, dst_nid, created_at)` key with another edge that a
            tombstone could not tell it from (write a base with `to_tables`).
        """
        if len(self.edges) < self._base_edge_count:
            raise Error(
                "SnapshotWorkingSet.delta_tables: the edge list shrank from "
                + String(self._base_edge_count)
                + " to "
                + String(len(self.edges))
                + " since the load; write a full snapshot"
            )
        if len(self.episodes) < self._base_episode_count:
            raise Error(
                "SnapshotWorkingSet.delta_tables: the episode list shrank from "
                + String(self._base_episode_count)
                + " to "
                + String(len(self.episodes))
                + " since the load; write a full snapshot"
            )
        self._check_unique_nids()
        self._check_no_loaded_entity_dropped()
        var tables = Slab[KgTable]()
        var changed = self._changed_entity_indices()
        if len(changed) > 0:
            tables.append(
                KgTable(
                    String(TABLE_ENTITIES),
                    build_entities_batch(
                        self.entities, changed, self.embedding_dim
                    ),
                    SCHEMA_VERSION_ENTITIES,
                )
            )
            tables.append(
                KgTable(
                    String(TABLE_ENTITIES_EMBEDDING),
                    build_embedding_projection_batch(
                        self.entities, changed, self.embedding_dim
                    ),
                    SCHEMA_VERSION_ENTITIES_EMBEDDING,
                )
            )
        var added_edges = List[Int]()
        for i in range(self._base_edge_count, len(self.edges)):
            added_edges.append(i)
        if len(added_edges) > 0:
            tables.append(
                KgTable(
                    String(TABLE_EDGES),
                    build_edges_batch(self.edges, added_edges, self.entities),
                    SCHEMA_VERSION_EDGES,
                )
            )
        var closed = self.tombstone_edge_indices()
        self._check_closures_unambiguous(closed)
        if len(closed) > 0:
            tables.append(
                KgTable(
                    String(TABLE_EDGES_TOMBSTONE),
                    build_tombstone_batch(self.edges, closed),
                    SCHEMA_VERSION_EDGES,
                )
            )
        var added_episodes = List[Int]()
        for i in range(self._base_episode_count, len(self.episodes)):
            added_episodes.append(i)
        if len(added_episodes) > 0:
            tables.append(
                KgTable(
                    String(TABLE_EPISODES),
                    build_episodes_batch(self.episodes, added_episodes),
                    SCHEMA_VERSION_EPISODES,
                )
            )
        return tables^


def _edge_key(src: Int64, dst: Int64, created: Int64) -> String:
    return String(src) + "/" + String(dst) + "/" + String(created)
