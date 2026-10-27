# =============================================================================
# working_rows -- the entity and episode rows of the in-memory working set.
# =============================================================================
#
# The working set (`working_set`) holds three lists of plain value rows: the
# entities and episodes defined here, and the edges of `bitemporal`
# (`WorkingEdge`). Each mirrors the columns of its table in
# `komira_kg_format.schemas`; none holds a pointer, so a row is copied and moved
# like any value.
#
# `WorkingEntity.name_embedding` is held unpacked, as f64: the dedup cosine read
# runs on it directly, and the writer packs it to the table's f32 cell. The
# vector's length is the graph's embedding dimension, which the working set
# checks when a row is added or written (see `working_set`).
#
# `partition_id` and `facet` are opaque strings the host chooses; this package
# gives neither a meaning beyond equality.
# =============================================================================


@fieldwise_init
struct WorkingEntity(Copyable, Movable):
    """One entity of the working set, with the columns of the `entities` table.

    Fields:
        nid: The dense adjacency id (the edges' `src_nid` / `dst_nid` join key).
        uuid: The stable external id (payload).
        partition_id: The opaque id of the partition the entity belongs to.
        name: The entity's surface name.
        name_embedding: The name embedding, unpacked to f64; its length is the
            graph's embedding dimension.
        summary: The entity summary, "" if none.
        attrs: The attributes as JSON text, "{}" if none.
    """

    var nid: Int64
    var uuid: String
    var partition_id: String
    var name: String
    var name_embedding: List[Float64]
    var summary: String
    var attrs: String


struct WorkingEpisode(Copyable, Movable):
    """One episode row (append-only provenance), with the columns of the
    `episodes` table.

    Fields:
        uuid: The stable external episode id.
        partition_id: The opaque id of the partition the episode belongs to.
        body: The raw episode text.
        ts: The system (ingest) time, in the unit the graph stamps.
        valid_at: The event time the episode refers to.
        facet: The opaque facet label the host stamped, "" for none.
    """

    var uuid: String
    var partition_id: String
    var body: String
    var ts: Int64
    var valid_at: Int64
    var facet: String

    def __init__(
        out self,
        var uuid: String,
        var partition_id: String,
        var body: String,
        ts: Int64,
        valid_at: Int64,
        var facet: String = String(""),
    ):
        """An episode row; `facet` is "" when the host has none."""
        self.uuid = uuid^
        self.partition_id = partition_id^
        self.body = body^
        self.ts = ts
        self.valid_at = valid_at
        self.facet = facet^
