# =============================================================================
# schemas -- the graph-table schemas the snapshot store writes and reads.
# =============================================================================
#
# Each table of a data graph has one schema, built here with `SchemaBuilder`.
# A table's version is a `SCHEMA_VERSION_*` constant; the snapshot manifest
# records it per table (`KgTableEntry.schema_version`) and a reader refuses a
# version it does not understand.
#
# EMBEDDING SHAPE: an embedding is one packed-bytes column carried as
# `LARGE_STRING` (the Parquet writer round-trips a string column and no other
# variable-length-bytes column). The cell is `dim * 4` little-endian f32 bytes
# (see `embedding`). `EMB_DIM` is the default dimension, an alias of
# `DEFAULT_EMBEDDING_DIM`; a graph's own dimension is in its manifest.
#
# NULLABILITY AND SENTINELS: no column is nullable. Keys and the dense adjacency
# ids are always present. The bi-temporal end columns (`invalid_at`,
# `expired_at`) are non-null INT64 holding `TS_OPEN_SENTINEL` while the interval
# is still open, so the "as of T" read is the plain filter
# `valid_at <= T and invalid_at > T` with no null handling (see the note on
# `TS_OPEN_SENTINEL` for the units it holds for).
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder

from .embedding import DEFAULT_EMBEDDING_DIM


# The default packed embedding dimension: the same constant as
# `DEFAULT_EMBEDDING_DIM`, not a second one.
comptime EMB_DIM: Int = DEFAULT_EMBEDDING_DIM

# The value of an open end column (`invalid_at`, `expired_at`): 999_999_999_999.
# The value is part of the stored data, so it is pinned here and not changed. It
# is above every epoch-second timestamp; as a count of milliseconds or
# microseconds it is a date in 2001, so a writer that stamps times in those units
# must not rely on `invalid_at > T` to keep an open edge, and must test for the
# sentinel itself.
comptime TS_OPEN_SENTINEL: Int64 = 9999_9999_9999

# Per-table schema versions. `episodes` is at 2: version 2 added the sixth
# column, `capability`. A reader of the version-1 five-column layout folds a
# missing `capability` column to "" (unfiltered), so a version-1 snapshot stays
# readable.
comptime SCHEMA_VERSION_EPISODES: Int64 = 2
comptime SCHEMA_VERSION_ENTITIES: Int64 = 1
comptime SCHEMA_VERSION_EDGES: Int64 = 1
comptime SCHEMA_VERSION_COMMUNITIES: Int64 = 1
comptime SCHEMA_VERSION_COMMUNITY_REPORTS: Int64 = 1
comptime SCHEMA_VERSION_ENTITIES_EMBEDDING: Int64 = 1


def episodes_schema() -> Schema:
    """The `episodes` table: raw provenance, append-only. A new snapshot grows
    the table; a row is never rewritten. `body` is the raw episode text.

    Returns:
        The six-column schema, version `SCHEMA_VERSION_EPISODES`.
    """
    var sb = SchemaBuilder()
    sb.add_field(Field("uuid", ArrowType.STRING, False))  # stable external id
    sb.add_field(Field("group_id", ArrowType.STRING, False))  # partition
    sb.add_field(Field("body", ArrowType.LARGE_STRING, False))  # raw text
    sb.add_field(Field("ts", ArrowType.INT64, False))  # ingest time
    sb.add_field(Field("valid_at", ArrowType.INT64, False))  # event time
    sb.add_field(Field("capability", ArrowType.STRING, False))  # "" = unfiltered
    return sb.build()


def entities_schema() -> Schema:
    """The `entities` table. `nid` is the dense integer adjacency id the edge
    table joins on, so traversal keys on `nid` and the string `uuid` is payload.

    Returns:
        The seven-column schema, version `SCHEMA_VERSION_ENTITIES`.
    """
    var sb = SchemaBuilder()
    sb.add_field(Field("nid", ArrowType.INT64, False))  # dense adjacency id
    sb.add_field(Field("uuid", ArrowType.STRING, False))  # stable external id
    sb.add_field(Field("group_id", ArrowType.STRING, False))
    sb.add_field(Field("name", ArrowType.STRING, False))
    sb.add_field(Field("name_embedding", ArrowType.LARGE_STRING, False))
    sb.add_field(Field("summary", ArrowType.LARGE_STRING, False))
    sb.add_field(Field("attrs", ArrowType.LARGE_STRING, False))  # JSON text
    return sb.build()


def edges_schema() -> Schema:
    """The `edges` table. Traversal is an integer join on `src_nid` and
    `dst_nid`; the uuids are payload. `invalid_at` and `expired_at` hold
    `TS_OPEN_SENTINEL` while open.

    Returns:
        The twelve-column schema, version `SCHEMA_VERSION_EDGES`.
    """
    var sb = SchemaBuilder()
    sb.add_field(Field("src_nid", ArrowType.INT64, False))  # join key
    sb.add_field(Field("dst_nid", ArrowType.INT64, False))  # join key
    sb.add_field(Field("src_uuid", ArrowType.STRING, False))  # payload
    sb.add_field(Field("dst_uuid", ArrowType.STRING, False))  # payload
    sb.add_field(Field("fact", ArrowType.LARGE_STRING, False))
    sb.add_field(Field("fact_embedding", ArrowType.LARGE_STRING, False))
    sb.add_field(Field("valid_at", ArrowType.INT64, False))  # event-time start
    sb.add_field(Field("invalid_at", ArrowType.INT64, False))  # event-time end
    sb.add_field(Field("expired_at", ArrowType.INT64, False))  # system-time end
    sb.add_field(Field("created_at", ArrowType.INT64, False))  # system time
    sb.add_field(Field("reference_time", ArrowType.INT64, False))
    sb.add_field(Field("source", ArrowType.STRING, False))  # "" = unattributed
    return sb.build()


def edges_tombstone_schema() -> Schema:
    """The delta-only `edges_tombstone` table. For each edge a delta
    superseded it carries the narrow row key `(src_nid, dst_nid, created_at)`
    and the two bi-temporal columns that changed, not the whole edge; a reader
    applies them over the matching earlier edge. It never appears in a full base
    snapshot, only inside a delta object.

    Returns:
        The five-column schema.
    """
    var sb = SchemaBuilder()
    sb.add_field(Field("src_nid", ArrowType.INT64, False))  # row key, part 1
    sb.add_field(Field("dst_nid", ArrowType.INT64, False))  # row key, part 2
    sb.add_field(Field("created_at", ArrowType.INT64, False))  # row key, part 3
    sb.add_field(Field("invalid_at", ArrowType.INT64, False))  # new event end
    sb.add_field(Field("expired_at", ArrowType.INT64, False))  # new system end
    return sb.build()


def entities_embedding_schema() -> Schema:
    """The delta-only `entities_embedding` projection. For each entity a delta
    added it carries the dense `nid` and the packed `name_embedding` cell, and
    nothing else. A reader folds the chain's projection rows (a later delta
    wins by `nid`) into one embedding column, so a near-duplicate search needs
    not load the full entities table. It never appears in a full base snapshot.

    Returns:
        The two-column schema, version `SCHEMA_VERSION_ENTITIES_EMBEDDING`.
    """
    var sb = SchemaBuilder()
    sb.add_field(Field("nid", ArrowType.INT64, False))  # join and later-wins key
    sb.add_field(Field("name_embedding", ArrowType.LARGE_STRING, False))
    return sb.build()


def communities_schema() -> Schema:
    """The `communities` table: the community tree. `member_uuids` is a JSON
    array carried as a string column, because a list column is unwritable.

    Returns:
        The four-column schema, version `SCHEMA_VERSION_COMMUNITIES`.
    """
    var sb = SchemaBuilder()
    sb.add_field(Field("level", ArrowType.INT64, False))
    sb.add_field(Field("community_id", ArrowType.INT64, False))
    sb.add_field(Field("parent_community_id", ArrowType.INT64, False))
    sb.add_field(Field("member_uuids", ArrowType.LARGE_STRING, False))
    return sb.build()


def community_reports_schema() -> Schema:
    """The `community_reports` table: the bottom-up summary of each community.
    `findings` is a JSON array carried as a string column.

    Returns:
        The six-column schema, version `SCHEMA_VERSION_COMMUNITY_REPORTS`.
    """
    var sb = SchemaBuilder()
    sb.add_field(Field("community_id", ArrowType.INT64, False))
    sb.add_field(Field("level", ArrowType.INT64, False))
    sb.add_field(Field("title", ArrowType.STRING, False))
    sb.add_field(Field("summary", ArrowType.LARGE_STRING, False))
    sb.add_field(Field("findings", ArrowType.LARGE_STRING, False))
    sb.add_field(Field("rating", ArrowType.FLOAT64, False))
    return sb.build()
