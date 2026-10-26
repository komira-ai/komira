# =============================================================================
# working_codec -- table batches to working rows, and working rows to batches.
# =============================================================================
#
# The working set reads its rows out of the Parquet and framed-blob batches a
# snapshot and its deltas hold, and writes them back as batches for the
# snapshot store. This module is that conversion, and it is where bytes from
# storage are refused when they are wrong.
#
# READING. A table's Parquet bytes go to `decode_parquet_file_from_bytes`
# (bytes in, batch out; nothing touches a file system), a delta object goes to
# the delta codec (framed blob or Parquet, by its tag byte). Before a table is
# decoded its stamped schema version is held to the version this build reads
# (the row counts the manifests record are diagnostics and are not checked).
# Columns are
# read by position, because a framed delta names its columns `c0`, `c1`, ...;
# each column must be there and must have the type `schemas` gives it (a batch
# with more columns than the layout is read as the layout, the version gate
# being what guards a later layout). No column is nullable, so a null cell is an
# error.
#
# TEXT AND EMBEDDINGS. A cell is read through its length-based byte span, never
# through an accessor that returns a null-terminated string: an episode body or
# a fact may hold a NUL byte, and a packed embedding routinely does. A text cell
# must be UTF-8. An embedding cell must hold exactly the manifest's dimension
# (`unpack_embedding_checked`).
#
# ROWS. A node id is a dense non-negative integer below `Int64.MAX` (the working
# set mints `max + 1`), and no two entities of one table share one.
#
# WRITING. The builders check what they are given: an embedding of another
# length than the graph's, or with a component that is not finite as an f32,
# is refused, so a graph never holds vectors of two sizes. An edge's
# `fact_embedding` cell is written empty (a working edge carries no vector).
# =============================================================================

from std.math import isfinite

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.byte_view import ByteView
from komira_buffer.heap_region import HeapRegion
from komira_kg_format import (
    ChainView,
    SnapshotView,
    decode_framed_delta_to_batch,
    delta_object_is_framed,
    delta_object_parquet_bytes,
    edges_schema,
    edges_tombstone_schema,
    entities_embedding_schema,
    entities_schema,
    episodes_schema,
    pack_embedding,
    unpack_embedding_checked,
)
from komira_kg_format.utf8_check import bytes_are_utf8
from komira_objectstore.store import CloneableConditionalWriteStore
from komira_parquet.file_decode import decode_parquet_file_from_bytes

from .bitemporal import WorkingEdge
from .working_rows import WorkingEntity, WorkingEpisode


comptime TABLE_ENTITIES: String = "entities"
comptime TABLE_EDGES: String = "edges"
comptime TABLE_EPISODES: String = "episodes"
# Delta-only: the narrow rows `{src_nid, dst_nid, created_at, invalid_at,
# expired_at}` of edges a delta closed; applied over the matching earlier edge.
comptime TABLE_EDGES_TOMBSTONE: String = "edges_tombstone"
# Delta-only: the narrow rows `{nid, name_embedding}` of the entities a delta
# added or changed.
comptime TABLE_ENTITIES_EMBEDDING: String = "entities_embedding"

# Column positions. entities: nid uuid partition_id name name_embedding summary
# attrs.
comptime _ENT_NID: Int = 0
comptime _ENT_UUID: Int = 1
comptime _ENT_PARTITION: Int = 2
comptime _ENT_NAME: Int = 3
comptime _ENT_EMBEDDING: Int = 4
comptime _ENT_SUMMARY: Int = 5
comptime _ENT_ATTRS: Int = 6
comptime _ENT_COLUMNS: Int = 7
# edges: src_nid dst_nid src_uuid dst_uuid fact fact_embedding valid_at
# invalid_at expired_at created_at reference_time source.
comptime _EDGE_SRC_NID: Int = 0
comptime _EDGE_DST_NID: Int = 1
comptime _EDGE_FACT: Int = 4
comptime _EDGE_VALID_AT: Int = 6
comptime _EDGE_INVALID_AT: Int = 7
comptime _EDGE_EXPIRED_AT: Int = 8
comptime _EDGE_CREATED_AT: Int = 9
comptime _EDGE_REFERENCE_TIME: Int = 10
comptime _EDGE_SOURCE: Int = 11
comptime _EDGE_COLUMNS: Int = 12
# episodes: uuid partition_id body ts valid_at facet.
comptime _EP_UUID: Int = 0
comptime _EP_PARTITION: Int = 1
comptime _EP_BODY: Int = 2
comptime _EP_TS: Int = 3
comptime _EP_VALID_AT: Int = 4
comptime _EP_FACET: Int = 5
comptime _EP_COLUMNS: Int = 6
# edges_tombstone: src_nid dst_nid created_at invalid_at expired_at.
comptime _TOMB_SRC: Int = 0
comptime _TOMB_DST: Int = 1
comptime _TOMB_CREATED: Int = 2
comptime _TOMB_INVALID: Int = 3
comptime _TOMB_EXPIRED: Int = 4
comptime _TOMB_COLUMNS: Int = 5


# -----------------------------------------------------------------------------
# Fetching and decoding a table object.
# -----------------------------------------------------------------------------


def _decode_parquet(bytes: List[UInt8]) raises -> RecordBatch:
    # SAFETY: the view borrows `bytes`, which lives to the end of this function,
    # and `decode_parquet_file_from_bytes` returns a batch that owns its data,
    # so nothing borrowed from `bytes` escapes.
    var file = ByteView[origin_of(bytes)](bytes.unsafe_ptr(), len(bytes))
    return decode_parquet_file_from_bytes(file)


def read_base_table[
    Store: CloneableConditionalWriteStore
](
    view: SnapshotView[Store], name: String, supported_version: Int64
) raises -> RecordBatch:
    """Fetch base table `name` off the snapshot and decode it.

    Raises:
        If the snapshot omits the table, stamps a newer schema version than
        `supported_version`, or holds bytes that are not a readable Parquet file.
    """
    view.assert_table_readable(name, supported_version)
    return _decode_parquet(view.get_table_bytes(name))


def read_delta_table[
    Store: CloneableConditionalWriteStore
](
    chain: ChainView[Store], di: Int, name: String, supported_version: Int64
) raises -> RecordBatch:
    """Fetch table `name` of delta number `di` and decode it, whichever way the
    object is framed.

    Raises:
        If `di` is out of range, the delta omits the table, stamps a newer schema
        version than `supported_version`, or the object is malformed.
    """
    if di < 0 or di >= chain.num_deltas():
        raise Error("read_delta_table: delta index " + String(di) + " out of range")
    var entry = chain.deltas[di].resolve(name)
    if entry.schema_version > supported_version:
        raise Error(
            "delta table "
            + name
            + " schema_version "
            + String(entry.schema_version)
            + " > reader-supported "
            + String(supported_version)
        )
    var body = chain.delta_object_bytes(di, name)
    if delta_object_is_framed(body):
        return decode_framed_delta_to_batch(body)
    return _decode_parquet(delta_object_parquet_bytes(body))


# -----------------------------------------------------------------------------
# Column access.
# -----------------------------------------------------------------------------


def _expect_columns(
    batch: RecordBatch,
    table: String,
    texts: List[Int],
    ints: List[Int],
    width: Int,
) raises:
    """Hold `batch` to the layout: at least `width` columns, the positions in
    `texts` string columns and those in `ints` INT64 columns."""
    if batch.num_columns() < width:
        raise Error(
            "table "
            + table
            + " has "
            + String(batch.num_columns())
            + " columns, expected at least "
            + String(width)
        )
    for i in range(len(texts)):
        var t = batch.column_arrow_type(texts[i])
        if t != ArrowType.STRING and t != ArrowType.LARGE_STRING:
            raise Error(
                "table " + table + ": column " + String(texts[i]) + " is not a string column"
            )
    for i in range(len(ints)):
        if batch.column_arrow_type(ints[i]) != ArrowType.INT64:
            raise Error(
                "table " + table + ": column " + String(ints[i]) + " is not INT64"
            )


def _text(
    cells: StringArray[HeapRegion], row: Int, table: String
) raises -> String:
    """The text cell at `row`, read by length; a null cell or bytes that are not
    UTF-8 are errors."""
    if cells.is_null(row):
        raise Error("table " + table + ": null cell in a required column, row " + String(row))
    var span = cells.get_span(row)
    if not bytes_are_utf8(span):
        raise Error("table " + table + ": text cell is not UTF-8, row " + String(row))
    # SAFETY: the bytes were just checked to be well-formed UTF-8 and the String
    # copies them.
    return String(StringSlice(unsafe_from_utf8=span))


def _int(
    cells: PrimitiveArray[DType.int64], row: Int, table: String
) raises -> Int64:
    if cells.is_null(row):
        raise Error("table " + table + ": null cell in a required column, row " + String(row))
    return cells.get(row)


def _check_nid(nid: Int64, table: String) raises:
    if nid < 0 or nid == Int64.MAX:
        raise Error(
            "table " + table + ": node id " + String(nid) + " is out of range"
        )


# -----------------------------------------------------------------------------
# Batches to rows.
# -----------------------------------------------------------------------------


def decode_entities(
    batch: RecordBatch, embedding_dim: Int
) raises -> List[WorkingEntity]:
    """The entity rows of an `entities` batch (a base table or a delta object).

    Args:
        batch: The decoded table.
        embedding_dim: The graph's dimension, from the base manifest; every
            embedding cell must be exactly this many components.

    Raises:
        On a missing or mistyped column, a null cell, text that is not UTF-8, a
        node id outside `[0, Int64.MAX)`, or an embedding cell of another length.
    """
    var t = TABLE_ENTITIES
    var texts = List[Int]()
    texts.append(_ENT_UUID)
    texts.append(_ENT_PARTITION)
    texts.append(_ENT_NAME)
    texts.append(_ENT_EMBEDDING)
    texts.append(_ENT_SUMMARY)
    texts.append(_ENT_ATTRS)
    var ints = List[Int]()
    ints.append(_ENT_NID)
    _expect_columns(batch, t, texts, ints, _ENT_COLUMNS)
    var nid_col = batch.column_as_primitive_int64(_ENT_NID)
    var uuid_col = batch.column_as_string(_ENT_UUID)
    var part_col = batch.column_as_string(_ENT_PARTITION)
    var name_col = batch.column_as_string(_ENT_NAME)
    var emb_col = batch.column_as_string(_ENT_EMBEDDING)
    var summary_col = batch.column_as_string(_ENT_SUMMARY)
    var attrs_col = batch.column_as_string(_ENT_ATTRS)
    var out = List[WorkingEntity]()
    for r in range(batch.num_rows()):
        var nid = _int(nid_col, r, t)
        _check_nid(nid, t)
        if emb_col.is_null(r):
            raise Error("table entities: null embedding cell, row " + String(r))
        var vec = unpack_embedding_checked(emb_col.get_span(r), embedding_dim)
        out.append(
            WorkingEntity(
                nid,
                _text(uuid_col, r, t),
                _text(part_col, r, t),
                _text(name_col, r, t),
                vec^,
                _text(summary_col, r, t),
                _text(attrs_col, r, t),
            )
        )
    return out^


def decode_edges(batch: RecordBatch) raises -> List[WorkingEdge]:
    """The edge rows of an `edges` batch. The `predicate` of a working edge is
    not a column (the relation rides in `fact`), so it reads back as "".

    Raises:
        On a missing or mistyped column, a null cell or text that is not UTF-8.
    """
    var t = TABLE_EDGES
    var texts = List[Int]()
    texts.append(2)
    texts.append(3)
    texts.append(_EDGE_FACT)
    texts.append(5)
    texts.append(_EDGE_SOURCE)
    var ints = List[Int]()
    ints.append(_EDGE_SRC_NID)
    ints.append(_EDGE_DST_NID)
    ints.append(_EDGE_VALID_AT)
    ints.append(_EDGE_INVALID_AT)
    ints.append(_EDGE_EXPIRED_AT)
    ints.append(_EDGE_CREATED_AT)
    ints.append(_EDGE_REFERENCE_TIME)
    _expect_columns(batch, t, texts, ints, _EDGE_COLUMNS)
    var src_col = batch.column_as_primitive_int64(_EDGE_SRC_NID)
    var dst_col = batch.column_as_primitive_int64(_EDGE_DST_NID)
    var fact_col = batch.column_as_string(_EDGE_FACT)
    var valid_col = batch.column_as_primitive_int64(_EDGE_VALID_AT)
    var invalid_col = batch.column_as_primitive_int64(_EDGE_INVALID_AT)
    var expired_col = batch.column_as_primitive_int64(_EDGE_EXPIRED_AT)
    var created_col = batch.column_as_primitive_int64(_EDGE_CREATED_AT)
    var refts_col = batch.column_as_primitive_int64(_EDGE_REFERENCE_TIME)
    var source_col = batch.column_as_string(_EDGE_SOURCE)
    var out = List[WorkingEdge]()
    for r in range(batch.num_rows()):
        out.append(
            WorkingEdge(
                _int(src_col, r, t),
                _int(dst_col, r, t),
                String(""),
                _text(fact_col, r, t),
                _int(valid_col, r, t),
                _int(invalid_col, r, t),
                _int(expired_col, r, t),
                _int(created_col, r, t),
                _int(refts_col, r, t),
                _text(source_col, r, t),
            )
        )
    return out^


def decode_episodes(batch: RecordBatch) raises -> List[WorkingEpisode]:
    """The episode rows of an `episodes` batch.

    Raises:
        On a missing or mistyped column, a null cell or text that is not UTF-8.
    """
    var t = TABLE_EPISODES
    var texts = List[Int]()
    texts.append(_EP_UUID)
    texts.append(_EP_PARTITION)
    texts.append(_EP_BODY)
    texts.append(_EP_FACET)
    var ints = List[Int]()
    ints.append(_EP_TS)
    ints.append(_EP_VALID_AT)
    _expect_columns(batch, t, texts, ints, _EP_COLUMNS)
    var uuid_col = batch.column_as_string(_EP_UUID)
    var part_col = batch.column_as_string(_EP_PARTITION)
    var body_col = batch.column_as_string(_EP_BODY)
    var ts_col = batch.column_as_primitive_int64(_EP_TS)
    var valid_col = batch.column_as_primitive_int64(_EP_VALID_AT)
    var facet_col = batch.column_as_string(_EP_FACET)
    var out = List[WorkingEpisode]()
    for r in range(batch.num_rows()):
        out.append(
            WorkingEpisode(
                _text(uuid_col, r, t),
                _text(part_col, r, t),
                _text(body_col, r, t),
                _int(ts_col, r, t),
                _int(valid_col, r, t),
                _text(facet_col, r, t),
            )
        )
    return out^


@fieldwise_init
struct EdgeClosure(Copyable, Movable):
    """One row of an `edges_tombstone` delta table: the key of an edge and its
    new end times.

    Fields:
        src_nid: Row key, part 1.
        dst_nid: Row key, part 2.
        created_at: Row key, part 3.
        invalid_at: The edge's new event-time end.
        expired_at: The edge's new system-time end.
    """

    var src_nid: Int64
    var dst_nid: Int64
    var created_at: Int64
    var invalid_at: Int64
    var expired_at: Int64


def decode_edge_closures(batch: RecordBatch) raises -> List[EdgeClosure]:
    """The rows of an `edges_tombstone` delta batch.

    Raises:
        On a missing or mistyped column or a null cell.
    """
    var ints = List[Int]()
    for i in range(_TOMB_COLUMNS):
        ints.append(i)
    _expect_columns(batch, TABLE_EDGES_TOMBSTONE, List[Int](), ints, _TOMB_COLUMNS)
    var src = batch.column_as_primitive_int64(_TOMB_SRC)
    var dst = batch.column_as_primitive_int64(_TOMB_DST)
    var created = batch.column_as_primitive_int64(_TOMB_CREATED)
    var invalid = batch.column_as_primitive_int64(_TOMB_INVALID)
    var expired = batch.column_as_primitive_int64(_TOMB_EXPIRED)
    var t = TABLE_EDGES_TOMBSTONE
    var out = List[EdgeClosure]()
    for r in range(batch.num_rows()):
        out.append(
            EdgeClosure(
                _int(src, r, t),
                _int(dst, r, t),
                _int(created, r, t),
                _int(invalid, r, t),
                _int(expired, r, t),
            )
        )
    return out^


# -----------------------------------------------------------------------------
# Rows to batches.
# -----------------------------------------------------------------------------


def _i64_col(values: List[Int64]) -> Column[HeapRegion]:
    return Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(values)
    )


def _str_col(values: List[String]) raises -> Column[HeapRegion]:
    return Column.from_string(StringArray.from_strings(values))


def check_embedding(
    v: List[Float64], embedding_dim: Int, what: String
) raises:
    """Refuse a vector that is not `embedding_dim` components of finite f32s.

    Raises:
        If the length differs from `embedding_dim`, or a component is not finite
        once narrowed to f32 (a NaN, an infinity, or a value beyond the f32
        range).
    """
    if len(v) != embedding_dim:
        raise Error(
            what
            + ": embedding has "
            + String(len(v))
            + " components but the graph's dimension is "
            + String(embedding_dim)
        )
    for i in range(len(v)):
        if not isfinite(Float32(v[i])):
            raise Error(
                what
                + ": embedding component "
                + String(i)
                + " is not a finite f32"
            )


def build_entities_batch(
    entities: List[WorkingEntity], idxs: List[Int], embedding_dim: Int
) raises -> RecordBatch:
    """The `entities` batch over the rows `idxs`, embeddings packed.

    Raises:
        On an embedding that fails `check_embedding`.
    """
    var nids = List[Int64]()
    var uuids = List[String]()
    var parts = List[String]()
    var names = List[String]()
    var embs = List[String]()
    var summaries = List[String]()
    var attrs = List[String]()
    for k in range(len(idxs)):
        ref e = entities[idxs[k]]
        check_embedding(e.name_embedding, embedding_dim, "entity " + String(e.nid))
        nids.append(e.nid)
        uuids.append(e.uuid)
        parts.append(e.partition_id)
        names.append(e.name)
        embs.append(pack_embedding(e.name_embedding))
        summaries.append(e.summary)
        attrs.append(e.attrs)
    var rb = RecordBatchBuilder()
    rb.add_column(_i64_col(nids))
    rb.add_column(_str_col(uuids))
    rb.add_column(_str_col(parts))
    rb.add_column(_str_col(names))
    rb.add_column(_str_col(embs))
    rb.add_column(_str_col(summaries))
    rb.add_column(_str_col(attrs))
    return rb.build(entities_schema())


def build_embedding_projection_batch(
    entities: List[WorkingEntity], idxs: List[Int], embedding_dim: Int
) raises -> RecordBatch:
    """The narrow `entities_embedding` batch over the rows `idxs`: the node id
    and the same packed cell the `entities` table carries.

    Raises:
        On an embedding that fails `check_embedding`.
    """
    var nids = List[Int64]()
    var embs = List[String]()
    for k in range(len(idxs)):
        ref e = entities[idxs[k]]
        check_embedding(e.name_embedding, embedding_dim, "entity " + String(e.nid))
        nids.append(e.nid)
        embs.append(pack_embedding(e.name_embedding))
    var rb = RecordBatchBuilder()
    rb.add_column(_i64_col(nids))
    rb.add_column(_str_col(embs))
    return rb.build(entities_embedding_schema())


def build_edges_batch(
    edges: List[WorkingEdge], idxs: List[Int], entities: List[WorkingEntity]
) raises -> RecordBatch:
    """The `edges` batch over the rows `idxs`.

    The uuid pair of each edge is looked up from `entities` by node id (payload;
    "" for a node the entities do not hold, the first entity winning if a node
    id repeats), and `fact_embedding` is written empty.
    """
    var uuid_of = Dict[Int64, String]()
    for i in range(len(entities)):
        if entities[i].nid not in uuid_of:
            uuid_of[entities[i].nid] = entities[i].uuid
    var src = List[Int64]()
    var dst = List[Int64]()
    var src_uuid = List[String]()
    var dst_uuid = List[String]()
    var facts = List[String]()
    var fembs = List[String]()
    var valid_at = List[Int64]()
    var invalid_at = List[Int64]()
    var expired_at = List[Int64]()
    var created_at = List[Int64]()
    var reference_time = List[Int64]()
    var sources = List[String]()
    for k in range(len(idxs)):
        ref ed = edges[idxs[k]]
        src.append(ed.src_nid)
        dst.append(ed.dst_nid)
        src_uuid.append(uuid_of.get(ed.src_nid, String("")))
        dst_uuid.append(uuid_of.get(ed.dst_nid, String("")))
        facts.append(ed.fact)
        fembs.append(String(""))
        valid_at.append(ed.valid_at)
        invalid_at.append(ed.invalid_at)
        expired_at.append(ed.expired_at)
        created_at.append(ed.created_at)
        reference_time.append(ed.reference_time)
        sources.append(ed.source)
    var rb = RecordBatchBuilder()
    rb.add_column(_i64_col(src))
    rb.add_column(_i64_col(dst))
    rb.add_column(_str_col(src_uuid))
    rb.add_column(_str_col(dst_uuid))
    rb.add_column(_str_col(facts))
    rb.add_column(_str_col(fembs))
    rb.add_column(_i64_col(valid_at))
    rb.add_column(_i64_col(invalid_at))
    rb.add_column(_i64_col(expired_at))
    rb.add_column(_i64_col(created_at))
    rb.add_column(_i64_col(reference_time))
    rb.add_column(_str_col(sources))
    return rb.build(edges_schema())


def build_tombstone_batch(
    edges: List[WorkingEdge], idxs: List[Int]
) raises -> RecordBatch:
    """The narrow `edges_tombstone` batch over the edges `idxs`: each row's key
    and its current end times."""
    var src = List[Int64]()
    var dst = List[Int64]()
    var created_at = List[Int64]()
    var invalid_at = List[Int64]()
    var expired_at = List[Int64]()
    for k in range(len(idxs)):
        ref ed = edges[idxs[k]]
        src.append(ed.src_nid)
        dst.append(ed.dst_nid)
        created_at.append(ed.created_at)
        invalid_at.append(ed.invalid_at)
        expired_at.append(ed.expired_at)
    var rb = RecordBatchBuilder()
    rb.add_column(_i64_col(src))
    rb.add_column(_i64_col(dst))
    rb.add_column(_i64_col(created_at))
    rb.add_column(_i64_col(invalid_at))
    rb.add_column(_i64_col(expired_at))
    return rb.build(edges_tombstone_schema())


def build_episodes_batch(
    episodes: List[WorkingEpisode], idxs: List[Int]
) raises -> RecordBatch:
    """The `episodes` batch over the rows `idxs`."""
    var uuids = List[String]()
    var parts = List[String]()
    var bodies = List[String]()
    var ts = List[Int64]()
    var valid_at = List[Int64]()
    var facets = List[String]()
    for k in range(len(idxs)):
        ref ep = episodes[idxs[k]]
        uuids.append(ep.uuid)
        parts.append(ep.partition_id)
        bodies.append(ep.body)
        ts.append(ep.ts)
        valid_at.append(ep.valid_at)
        facets.append(ep.facet)
    var rb = RecordBatchBuilder()
    rb.add_column(_str_col(uuids))
    rb.add_column(_str_col(parts))
    rb.add_column(_str_col(bodies))
    rb.add_column(_i64_col(ts))
    rb.add_column(_i64_col(valid_at))
    rb.add_column(_str_col(facets))
    return rb.build(episodes_schema())
