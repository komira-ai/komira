# =============================================================================
# search -- exact scans over a snapshot's tables, and rank fusion.
# =============================================================================
#
# Each search reads one table of a `SnapshotView` through the Parquet reader
# (bytes in, batch out; nothing is written to a file system) and scores it in
# Mojo. None needs an engine, an index or a clock.
#
#   node_similarity_search  top-k entities by cosine similarity of `name_embedding`
#   edge_fulltext_search    top-k edges by how often a term occurs in `fact`
#   edge_out_degree         how many edges leave one node
#   rrf_fuse                reciprocal-rank fusion of two ranked lists
#
# A `Hit.row` is the row index in the table that was read: entities for the
# similarity search, edges for the full-text search.
#
# REFUSALS. Before a table is decoded the snapshot's stamped schema version is
# held to the version this build reads. The table must hold the columns the
# search reads, under their names, with the types they have in `schemas`.
# `node_similarity_search` holds the query and every embedding cell to the
# dimension the manifest records: a cell of another length is an error, not a
# vector scored on a prefix, and so is a null cell, which the Parquet reader
# hands over as an empty one. Columns are found by name, so a table written with
# more columns, or the same columns in another order, reads the same.
#
# TEXT. The Parquet reader returns STRING for a LARGE_STRING column. A cell is
# always read through its length-based byte span, never through an accessor that
# returns a null-terminated string, so a NUL byte inside a fact or an embedding
# cell neither cuts the cell short nor hides a match after it.
# =============================================================================

from std.math import isfinite

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_buffer.byte_view import ByteView
from komira_objectstore.store import CloneableConditionalWriteStore
from komira_parquet.file_decode import decode_parquet_file_from_bytes

from .cosine import Hit, _top_k_desc, cosine_topk
from .embedding import unpack_embedding_checked
from .schemas import SCHEMA_VERSION_EDGES, SCHEMA_VERSION_ENTITIES
from .snapshot_view import SnapshotView


comptime TABLE_ENTITIES: String = "entities"
comptime TABLE_EDGES: String = "edges"
comptime _COL_NAME_EMBEDDING: String = "name_embedding"
comptime _COL_FACT: String = "fact"
comptime _COL_SRC_NID: String = "src_nid"


def _read_table[
    Store: CloneableConditionalWriteStore
](
    view: SnapshotView[Store], name: String, supported_version: Int64
) raises -> RecordBatch:
    """Fetch table `name` off the snapshot and decode it to one batch, after the
    schema-version gate.

    Raises:
        If the snapshot omits the table, stamps a newer schema version than
        `supported_version`, or holds bytes that are not a readable Parquet file.
    """
    view.assert_table_readable(name, supported_version)
    var bytes = view.get_table_bytes(name)
    # SAFETY: the view borrows `bytes`, which lives to the end of this function,
    # and `decode_parquet_file_from_bytes` returns a batch that owns its data, so
    # nothing borrowed from `bytes` escapes.
    var file = ByteView[origin_of(bytes)](bytes.unsafe_ptr(), len(bytes))
    return decode_parquet_file_from_bytes(file)


def _string_column(
    batch: RecordBatch, table: String, column: String
) raises -> Int:
    """The index of the string column `column` of `table`; an error naming both
    if it is absent or is not a string column."""
    var found: Int
    try:
        found = batch.column_by_name(column)
    except:
        raise Error(
            "search: table " + table + " has no column named " + column
        )
    var t = batch.column_arrow_type(found)
    if t != ArrowType.STRING and t != ArrowType.LARGE_STRING:
        raise Error(
            "search: column " + column + " of table " + table
            + " is not a string column"
        )
    return found


def node_similarity_search[
    Store: CloneableConditionalWriteStore
](view: SnapshotView[Store], query: List[Float64], k: Int) raises -> List[Hit]:
    """Top-k entities by cosine similarity of `name_embedding` to `query`.

    The result is exactly `cosine_topk` over the entities table's embedding
    column: score descending, equal scores ordered by lower row index first;
    `Hit.row` is the entities row.

    Parameters:
        Store: The object store the snapshot lives on (inferred).

    Args:
        view: The resolved snapshot.
        query: The query vector; it must have the snapshot's embedding dimension.
        k: How many hits to return; clamped to the row count, and a `k` of zero
            or less returns an empty list.

    Returns:
        Up to `k` hits.

    Raises:
        If the query does not have the snapshot's embedding dimension, if the
        table is absent, newer than this build reads, unreadable or lacks the
        column, or if any embedding cell (a null cell reads as an empty one) is
        not exactly that many packed f32 components.
    """
    var dim = view.embedding_dim()
    if dim <= 0:
        raise Error(
            "node_similarity_search: the snapshot records embedding dimension "
            + String(dim)
        )
    if len(query) != dim:
        raise Error(
            "node_similarity_search: query has "
            + String(len(query))
            + " components but the snapshot's embedding dimension is "
            + String(dim)
        )
    var batch = _read_table(view, TABLE_ENTITIES, SCHEMA_VERSION_ENTITIES)
    var col = _string_column(batch, TABLE_ENTITIES, _COL_NAME_EMBEDDING)
    var cells = batch.column_as_string(col)
    for r in range(len(cells)):
        # Held to the dimension; the vector itself is unpacked again by the
        # ranking below.
        _ = unpack_embedding_checked(cells.get_span(r), dim)
    return cosine_topk(cells, query, k)


def _count_occurrences[
    o: Origin[mut=False]
](haystack: Span[UInt8, o], needle: Span[UInt8, _]) -> Int:
    """Occurrences of `needle` in `haystack` as bytes, each match consumed so
    that matches do not overlap. An empty needle occurs zero times."""
    var n = len(haystack)
    var m = len(needle)
    if m == 0 or m > n:
        return 0
    var count = 0
    var i = 0
    while i <= n - m:
        var j = 0
        while j < m and haystack[i + j] == needle[j]:
            j += 1
        if j == m:
            count += 1
            i += m
        else:
            i += 1
    return count


def edge_fulltext_search[
    Store: CloneableConditionalWriteStore
](view: SnapshotView[Store], term: String, k: Int) raises -> List[Hit]:
    """Top-k edges whose `fact` contains `term`, ranked by occurrence count.

    The match is a case-sensitive byte match; occurrences do not overlap (`aa`
    occurs twice in `aaaa`). A row scores its occurrence count, a row without
    the term and a null fact are not hits, and an empty term matches nothing.
    `Hit.row` is the edges row.

    Parameters:
        Store: The object store the snapshot lives on (inferred).

    Args:
        view: The resolved snapshot.
        term: The text to count.
        k: How many hits to return; a `k` of zero or less returns an empty list.

    Returns:
        Up to `k` hits, score descending, equal scores ordered by lower row
        index first.

    Raises:
        If the table is absent, newer than this build reads, unreadable or lacks
        a string `fact` column.
    """
    var batch = _read_table(view, TABLE_EDGES, SCHEMA_VERSION_EDGES)
    var col = _string_column(batch, TABLE_EDGES, _COL_FACT)
    var facts = batch.column_as_string(col)
    var needle = term.as_bytes()
    var scored = List[Hit]()
    for r in range(len(facts)):
        if facts.is_null(r):
            continue
        var count = _count_occurrences(facts.get_span(r), needle)
        if count > 0:
            scored.append(Hit(r, Float64(count)))
    return _top_k_desc(scored^, k)


def edge_out_degree[
    Store: CloneableConditionalWriteStore
](view: SnapshotView[Store], src_nid: Int64) raises -> Int:
    """The number of edge rows whose `src_nid` is `src_nid`.

    Every row counts, whether or not its interval is still open: the count is a
    scan of the table as stored.

    Parameters:
        Store: The object store the snapshot lives on (inferred).

    Args:
        view: The resolved snapshot.
        src_nid: The node to count the out-edges of.

    Returns:
        The count; zero for a node with none.

    Raises:
        If the table is absent, newer than this build reads, unreadable or lacks
        an INT64 `src_nid` column.
    """
    var batch = _read_table(view, TABLE_EDGES, SCHEMA_VERSION_EDGES)
    var col: Int
    try:
        col = batch.column_by_name(_COL_SRC_NID)
    except:
        raise Error("search: table edges has no column named src_nid")
    if batch.column_arrow_type(col) != ArrowType.INT64:
        raise Error("search: column src_nid of table edges is not INT64")
    var src = batch.column_as_primitive_int64(col)
    var count = 0
    for r in range(batch.num_rows()):
        if src.get(r) == src_nid:
            count += 1
    return count


def _rrf_accumulate(
    mut ids: List[Int],
    mut scores: List[Float64],
    ranked: List[Hit],
    k_const: Float64,
):
    for rank in range(len(ranked)):
        var id = ranked[rank].row
        var share = 1.0 / (k_const + Float64(rank + 1))
        var found = False
        for j in range(len(ids)):
            if ids[j] == id:
                scores[j] += share
                found = True
                break
        if not found:
            ids.append(id)
            scores.append(share)


def rrf_fuse(
    list_a: List[Hit], list_b: List[Hit], k_const: Float64
) raises -> List[Hit]:
    """Reciprocal-rank fusion of two ranked lists.

    An id scores the sum over the lists it appears in of `1 / (k_const + rank)`,
    where rank is its 1-based position in that list (the order given, not the
    `Hit.score`). The ids of the two lists must be in one id space; the caller
    maps hits of different tables to a common id first. An id repeated inside
    one list is counted at each of its positions.

    Args:
        list_a: The first ranked list, best first.
        list_b: The second ranked list, best first.
        k_const: The damping constant, zero or more and finite (60.0 is common).

    Returns:
        Every id of either list with its fused score in `Hit.score`, score
        descending, equal scores ordered by lower id first.

    Raises:
        If `k_const` is negative, NaN or infinite.
    """
    if not isfinite(k_const) or k_const < 0.0:
        raise Error(
            "rrf_fuse: k_const must be finite and at least zero, got "
            + String(k_const)
        )
    var ids = List[Int]()
    var scores = List[Float64]()
    _rrf_accumulate(ids, scores, list_a, k_const)
    _rrf_accumulate(ids, scores, list_b, k_const)
    var fused = List[Hit](capacity=len(ids))
    for j in range(len(ids)):
        fused.append(Hit(ids[j], scores[j]))
    var n = len(fused)
    return _top_k_desc(fused^, n)
