# =============================================================================
# test_search_scans.mojo -- the exact scans over a snapshot's tables: embedding
#   similarity, full-text counts and out-degree (an in-memory object store; no
#   network, no clock, no environment).
# =============================================================================
#
#   similarity   the top-k of a written entities table is exactly cosine_topk over
#                the same rows (rows and scores), including cells with zero bytes,
#                tied rows (lower row first), k beyond the rows and k of zero.
#   dimension    a query of another length, a cell of another length (shorter,
#                longer, not a whole number of components), an empty cell and a
#                null cell (which the Parquet reader hands over as an empty
#                cell) are each refused, and a cell's dimension is held to the
#                manifest's, not to the query's.
#   full text    counts on stated rows: case-sensitive, non-overlapping, ranked by
#                count with ties by lower row, k-limited, an empty term matching
#                nothing, a fact with a NUL byte and a multi-byte term found whole.
#   out degree   counts on stated rows, over open and closed edges alike.
#   empty        a table with no rows returns no hits and degree zero.
#   refusals     a missing table, a stamped schema version newer than this build
#                reads, a table without the column, and a column of the wrong type.
#   columns      found by name, so extra columns and another order read the same.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_raises,
    assert_true,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab
from komira_kg_format import (
    Hit,
    KgSnapshotStore,
    KgTable,
    SnapshotView,
    SCHEMA_VERSION_EDGES,
    SCHEMA_VERSION_ENTITIES,
    TS_OPEN_SENTINEL,
    cosine_topk,
    edge_fulltext_search,
    edge_out_degree,
    node_similarity_search,
    pack_embedding,
)
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)


comptime Backend = SharedInMemoryConditionalStore
comptime Kg = KgSnapshotStore[SharedInMemoryConditionalStore]


def _ints(values: List[Int64]) -> Column[HeapRegion]:
    return Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(values)
    )


def _strs(values: List[String]) raises -> Column[HeapRegion]:
    return Column.from_string(StringArray.from_strings(values))


def _repeat(value: String, n: Int) -> List[String]:
    var out = List[String](capacity=n)
    for _ in range(n):
        out.append(value)
    return out^


def _zeros(n: Int) -> List[Int64]:
    var out = List[Int64](capacity=n)
    for _ in range(n):
        out.append(0)
    return out^


def _packed(rows: List[List[Float64]]) -> List[String]:
    var out = List[String](capacity=len(rows))
    for i in range(len(rows)):
        out.append(pack_embedding(rows[i]))
    return out^


def _entities(
    embeddings: List[String], null_rows: List[Int] = List[Int]()
) raises -> RecordBatch:
    """An entities table (the `schemas` layout) whose rows carry `embeddings`.

    The embedding cells of `null_rows` are written as nulls (the column is then
    nullable); every other column is required.
    """
    var n = len(embeddings)
    var nids = List[Int64](capacity=n)
    var names = List[String](capacity=n)
    for i in range(n):
        nids.append(Int64(i))
        names.append("n" + String(i))
    var rb = RecordBatchBuilder()
    rb.add_column(_ints(nids))
    rb.add_column(_strs(names))
    rb.add_column(_strs(_repeat("p", n)))
    rb.add_column(_strs(names))
    var valid = List[Bool](capacity=n)
    for i in range(n):
        valid.append(i not in null_rows)
    rb.add_column(
        Column.from_string(
            StringArray.from_strings_with_validity(embeddings, valid)
        )
    )
    rb.add_column(_strs(_repeat("", n)))
    rb.add_column(_strs(_repeat("{}", n)))
    var sb = SchemaBuilder()
    sb.add_field(Field("nid", ArrowType.INT64, False))
    sb.add_field(Field("uuid", ArrowType.STRING, False))
    sb.add_field(Field("partition_id", ArrowType.STRING, False))
    sb.add_field(Field("name", ArrowType.STRING, False))
    sb.add_field(
        Field("name_embedding", ArrowType.LARGE_STRING, len(null_rows) > 0)
    )
    sb.add_field(Field("summary", ArrowType.LARGE_STRING, False))
    sb.add_field(Field("attrs", ArrowType.LARGE_STRING, False))
    return rb.build(sb.build())


def _edges(
    src: List[Int64],
    facts: List[String],
    invalid_at: List[Int64] = List[Int64](),
) raises -> RecordBatch:
    """An edges table (the `schemas` layout) of the given sources and facts; every
    interval is open unless `invalid_at` says otherwise."""
    var n = len(src)
    var closed = invalid_at.copy()
    if len(closed) == 0:
        for _ in range(n):
            closed.append(TS_OPEN_SENTINEL)
    var rb = RecordBatchBuilder()
    rb.add_column(_ints(src))
    rb.add_column(_ints(_zeros(n)))
    rb.add_column(_strs(_repeat("s", n)))
    rb.add_column(_strs(_repeat("d", n)))
    rb.add_column(_strs(facts))
    rb.add_column(_strs(_repeat("", n)))
    rb.add_column(_ints(_zeros(n)))
    rb.add_column(_ints(closed))
    rb.add_column(_ints(_zeros(n)))
    rb.add_column(_ints(_zeros(n)))
    rb.add_column(_ints(_zeros(n)))
    rb.add_column(_strs(_repeat("", n)))
    var sb = SchemaBuilder()
    sb.add_field(Field("src_nid", ArrowType.INT64, False))
    sb.add_field(Field("dst_nid", ArrowType.INT64, False))
    sb.add_field(Field("src_uuid", ArrowType.STRING, False))
    sb.add_field(Field("dst_uuid", ArrowType.STRING, False))
    sb.add_field(Field("fact", ArrowType.LARGE_STRING, False))
    sb.add_field(Field("fact_embedding", ArrowType.LARGE_STRING, False))
    sb.add_field(Field("valid_at", ArrowType.INT64, False))
    sb.add_field(Field("invalid_at", ArrowType.INT64, False))
    sb.add_field(Field("expired_at", ArrowType.INT64, False))
    sb.add_field(Field("created_at", ArrowType.INT64, False))
    sb.add_field(Field("reference_time", ArrowType.INT64, False))
    sb.add_field(Field("source", ArrowType.STRING, False))
    return rb.build(sb.build())


def _one(
    name: String, var batch: RecordBatch, version: Int64
) -> Slab[KgTable]:
    var tables = Slab[KgTable]()
    tables.append(KgTable(name.copy(), batch^, version))
    return tables^


def _write(
    var tables: Slab[KgTable], dim: Int
) raises -> SnapshotView[Backend]:
    var kg = Kg(Backend(), "kg")
    _ = kg.write_snapshot(tables^, dim)
    return kg.open_latest()


def _entities_view(
    rows: List[List[Float64]], dim: Int
) raises -> SnapshotView[Backend]:
    return _write(
        _one("entities", _entities(_packed(rows)), SCHEMA_VERSION_ENTITIES),
        dim,
    )


def _edges_view(
    src: List[Int64], facts: List[String]
) raises -> SnapshotView[Backend]:
    return _write(_one("edges", _edges(src, facts), SCHEMA_VERSION_EDGES), 4)


def _binary(bytes: List[UInt8]) -> String:
    """A string holding exactly `bytes`, NUL bytes included."""
    return String(StringSlice(unsafe_from_utf8=Span[UInt8](bytes)))


def _assert_rows(hits: List[Hit], expected: List[Int]) raises:
    assert_equal(len(hits), len(expected))
    for i in range(len(expected)):
        assert_equal(hits[i].row, expected[i])


# --- similarity --------------------------------------------------------------


def _mixed_rows() -> List[List[Float64]]:
    return [
        [0.0, 1.0, 0.0, 0.0],  # orthogonal to the query below
        [1.0, 1.0, 0.0, 0.0],
        [1.0, 0.0, 0.0, 0.0],  # parallel
        [-1.0, 0.0, 0.0, 0.0],  # opposite
        [0.0, 0.0, 0.0, 0.0],  # zero vector: all-zero bytes
        [1.0, 0.0, 0.0, 0.0],  # ties row 2
        [0.5, 0.25, 0.125, 0.0625],
    ]


def test_similarity_equals_cosine_topk_over_the_same_rows() raises:
    var rows = _mixed_rows()
    var view = _entities_view(rows, 4)
    var query: List[Float64] = [1.0, 0.0, 0.0, 0.0]
    var reference = cosine_topk(
        StringArray.from_strings(_packed(rows)), query, 7
    )
    for k in [1, 3, 7]:
        var got = node_similarity_search(view, query, k)
        var want = cosine_topk(
            StringArray.from_strings(_packed(rows)), query, k
        )
        assert_equal(len(got), len(want))
        for i in range(len(want)):
            assert_equal(got[i].row, want[i].row)
            assert_equal(got[i].score, want[i].score)
    # Stated order: the parallel pair first (lower row first), then rows 6 and 1
    # (0.87 and 0.71), then the two rows scoring 0.0 (lower row first), then the
    # opposite vector.
    var all = node_similarity_search(view, query, 7)
    assert_equal(len(reference), 7)
    assert_equal(all[0].row, 2)
    assert_equal(all[1].row, 5)
    assert_equal(all[0].score, 1.0)
    assert_equal(all[2].row, 6)
    assert_equal(all[3].row, 1)
    assert_equal(all[4].row, 0)
    assert_equal(all[5].row, 4)
    assert_equal(all[6].row, 3)
    assert_equal(all[6].score, -1.0)


def test_similarity_k_beyond_the_rows_or_not_positive() raises:
    var view = _entities_view(_mixed_rows(), 4)
    var query: List[Float64] = [1.0, 0.0, 0.0, 0.0]
    assert_equal(len(node_similarity_search(view, query, 100)), 7)
    assert_equal(len(node_similarity_search(view, query, 0)), 0)
    assert_equal(len(node_similarity_search(view, query, -3)), 0)


def test_similarity_reads_the_dimension_from_the_manifest() raises:
    var rows: List[List[Float64]] = [[1.0, 0.0], [0.0, 1.0], [1.0, 1.0]]
    var view = _entities_view(rows, 2)
    assert_equal(view.embedding_dim(), 2)
    var query: List[Float64] = [0.0, 1.0]
    _assert_rows(node_similarity_search(view, query, 3), [1, 2, 0])


def test_a_query_of_another_dimension_is_refused() raises:
    var view = _entities_view(_mixed_rows(), 4)
    var shorter: List[Float64] = [1.0, 0.0, 0.0]
    var longer: List[Float64] = [1.0, 0.0, 0.0, 0.0, 0.0]
    with assert_raises(contains="query has 3 components"):
        _ = node_similarity_search(view, shorter, 3)
    with assert_raises(contains="query has 5 components"):
        _ = node_similarity_search(view, longer, 3)
    with assert_raises(contains="query has 0 components"):
        _ = node_similarity_search(view, List[Float64](), 3)


def test_a_cell_that_does_not_match_the_manifest_dimension_is_refused() raises:
    var query: List[Float64] = [1.0, 0.0, 0.0, 0.0]
    # The manifest says 4; row 2 holds 3 components, a vector from another
    # embedder. The query agrees with the manifest, so only the cell is wrong.
    var short_cell = _mixed_rows()
    short_cell[2] = [1.0, 0.0, 0.0]
    with assert_raises(contains="not a dimension of 4"):
        _ = node_similarity_search(_entities_view(short_cell, 4), query, 3)
    var long_cell = _mixed_rows()
    long_cell[6] = [1.0, 0.0, 0.0, 0.0, 0.0]
    with assert_raises(contains="not a dimension of 4"):
        _ = node_similarity_search(_entities_view(long_cell, 4), query, 3)
    # Every cell has the query's width but the manifest says another: refused
    # rather than scored.
    var wide_query: List[Float64] = [1.0, 0.0, 0.0, 0.0, 0.0]
    with assert_raises(contains="not a dimension of 5"):
        _ = node_similarity_search(
            _entities_view(_mixed_rows(), 5), wide_query, 3
        )


def test_a_cell_that_is_not_whole_components_is_refused() raises:
    var cells = _packed(_mixed_rows())
    cells[1] = cells[1] + "x"  # 17 bytes
    var view = _write(
        _one("entities", _entities(cells), SCHEMA_VERSION_ENTITIES), 4
    )
    var query: List[Float64] = [1.0, 0.0, 0.0, 0.0]
    with assert_raises(contains="17 bytes"):
        _ = node_similarity_search(view, query, 3)


def test_an_empty_embedding_cell_is_refused() raises:
    var cells = _packed(_mixed_rows())
    cells[3] = ""
    var view = _write(
        _one("entities", _entities(cells), SCHEMA_VERSION_ENTITIES), 4
    )
    var query: List[Float64] = [1.0, 0.0, 0.0, 0.0]
    with assert_raises(contains="0 bytes"):
        _ = node_similarity_search(view, query, 3)


def test_a_null_embedding_cell_arrives_empty_and_is_refused_as_zero_bytes() raises:
    var cells = _packed(_mixed_rows())
    var rows: List[Int] = [3]
    var view = _write(
        _one(
            "entities",
            _entities(cells, rows),
            SCHEMA_VERSION_ENTITIES,
        ),
        4,
    )
    var query: List[Float64] = [1.0, 0.0, 0.0, 0.0]
    with assert_raises(contains="embedding cell is 0 bytes"):
        _ = node_similarity_search(view, query, 3)


def test_similarity_over_an_empty_table_returns_nothing() raises:
    var view = _entities_view(List[List[Float64]](), 4)
    assert_equal(view.row_count("entities"), 0)
    var query: List[Float64] = [1.0, 0.0, 0.0, 0.0]
    assert_equal(len(node_similarity_search(view, query, 5)), 0)


# --- full text ---------------------------------------------------------------


def _fact_rows() -> List[String]:
    return [
        "alpha beta alpha",  # 0: two
        "beta",  # 1: none
        "alpha",  # 2: one
        "alpha alpha alpha",  # 3: three
        "ALPHA Alpha",  # 4: none (case-sensitive)
        "alpha-alpha",  # 5: two
        "",  # 6: none
    ]


def test_fulltext_counts_on_stated_rows() raises:
    var view = _edges_view(_zeros(7), _fact_rows())
    var hits = _alpha(view, 10)
    _assert_rows(hits, [3, 0, 5, 2])
    assert_equal(hits[0].score, 3.0)
    assert_equal(hits[1].score, 2.0)
    assert_equal(hits[2].score, 2.0)  # ties with row 0: lower row first
    assert_equal(hits[3].score, 1.0)


def _alpha(view: SnapshotView[Backend], k: Int) raises -> List[Hit]:
    return edge_fulltext_search(view, "alpha", k)


def test_fulltext_k_limits_the_hits() raises:
    var view = _edges_view(_zeros(7), _fact_rows())
    _assert_rows(_alpha(view, 2), [3, 0])
    assert_equal(len(_alpha(view, 0)), 0)
    assert_equal(len(_alpha(view, -1)), 0)


def test_fulltext_matches_do_not_overlap() raises:
    var facts: List[String] = ["aaaa", "aaa", "a"]
    var view = _edges_view(_zeros(3), facts)
    var hits = edge_fulltext_search(view, "aa", 5)
    _assert_rows(hits, [0, 1])
    assert_equal(hits[0].score, 2.0)
    assert_equal(hits[1].score, 1.0)


def test_fulltext_an_empty_term_matches_nothing() raises:
    var view = _edges_view(_zeros(7), _fact_rows())
    assert_equal(len(edge_fulltext_search(view, "", 10)), 0)


def test_fulltext_a_term_longer_than_every_fact_matches_nothing() raises:
    var view = _edges_view(_zeros(2), ["ab", "abc"])
    assert_equal(len(edge_fulltext_search(view, "abcd", 10)), 0)


def test_fulltext_finds_a_term_after_a_nul_byte() raises:
    var facts = List[String]()
    facts.append(_binary([0x78, 0x00, 0x61, 0x6C]))
    facts.append("x")
    facts.append(_binary([0x61, 0x6C, 0x00, 0x61, 0x6C]))
    var view = _edges_view(_zeros(3), facts)
    # Row 0 is "x", NUL, "al"; row 2 is "al", NUL, "al": a reader that stops a
    # cell at its first NUL would see "al" in row 2 once and "x" in row 0.
    var hits = edge_fulltext_search(view, "al", 5)
    _assert_rows(hits, [2, 0])
    assert_equal(hits[0].score, 2.0)
    assert_equal(hits[1].score, 1.0)


def test_fulltext_matches_a_multibyte_term_whole() raises:
    var facts: List[String] = ["café au lait", "cafe", "éé"]
    var view = _edges_view(_zeros(3), facts)
    var hits = edge_fulltext_search(view, "é", 5)
    _assert_rows(hits, [2, 0])
    assert_equal(hits[0].score, 2.0)
    assert_equal(len(edge_fulltext_search(view, "e", 5)), 1)


def test_fulltext_over_an_empty_table_returns_nothing() raises:
    var view = _edges_view(List[Int64](), List[String]())
    assert_equal(view.row_count("edges"), 0)
    assert_equal(len(edge_fulltext_search(view, "alpha", 5)), 0)


# --- out degree --------------------------------------------------------------


def test_out_degree_counts_on_stated_rows() raises:
    var src: List[Int64] = [1, 1, 2, 3, 1, 7]
    var view = _edges_view(src, _repeat("f", 6))
    assert_equal(edge_out_degree(view, 1), 3)
    assert_equal(edge_out_degree(view, 2), 1)
    assert_equal(edge_out_degree(view, 3), 1)
    assert_equal(edge_out_degree(view, 7), 1)
    assert_equal(edge_out_degree(view, 4), 0)
    assert_equal(edge_out_degree(view, -1), 0)


def test_out_degree_counts_closed_edges_too() raises:
    var src: List[Int64] = [5, 5, 5]
    var closed: List[Int64] = [TS_OPEN_SENTINEL, 100, 200]
    var view = _write(
        _one("edges", _edges(src, _repeat("f", 3), closed), 1), 4
    )
    assert_equal(edge_out_degree(view, 5), 3)


def test_out_degree_over_an_empty_table_is_zero() raises:
    var view = _edges_view(List[Int64](), List[String]())
    assert_equal(edge_out_degree(view, 1), 0)


# --- refusals and columns ----------------------------------------------------


def test_a_missing_table_is_refused() raises:
    var query: List[Float64] = [1.0, 0.0, 0.0, 0.0]
    var only_edges = _edges_view(_zeros(2), ["a", "b"])
    with assert_raises(contains="table not present"):
        _ = node_similarity_search(only_edges, query, 3)
    var only_entities = _entities_view(_mixed_rows(), 4)
    with assert_raises(contains="table not present"):
        _ = edge_fulltext_search(only_entities, "a", 3)
    with assert_raises(contains="table not present"):
        _ = edge_out_degree(only_entities, 1)


def test_a_table_stamped_with_a_newer_schema_version_is_refused() raises:
    var query: List[Float64] = [1.0, 0.0, 0.0, 0.0]
    var entities = _write(
        _one(
            "entities",
            _entities(_packed(_mixed_rows())),
            SCHEMA_VERSION_ENTITIES + 1,
        ),
        4,
    )
    with assert_raises(contains="schema_version"):
        _ = node_similarity_search(entities, query, 3)
    var edges = _write(
        _one("edges", _edges(_zeros(1), ["a"]), SCHEMA_VERSION_EDGES + 1), 4
    )
    with assert_raises(contains="schema_version"):
        _ = edge_fulltext_search(edges, "a", 3)
    with assert_raises(contains="schema_version"):
        _ = edge_out_degree(edges, 0)


def test_a_table_without_the_column_is_refused() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field("nid", ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    var ids: List[Int64] = [1, 2]
    rb.add_column(_ints(ids))
    var thin = _write(_one("entities", rb.build(sb.build()), 1), 4)
    var query: List[Float64] = [1.0, 0.0, 0.0, 0.0]
    with assert_raises(contains="no column named name_embedding"):
        _ = node_similarity_search(thin, query, 3)

    var sb2 = SchemaBuilder()
    sb2.add_field(Field("dst_nid", ArrowType.INT64, False))
    var rb2 = RecordBatchBuilder()
    rb2.add_column(_ints(ids))
    var edges = _write(_one("edges", rb2.build(sb2.build()), 1), 4)
    with assert_raises(contains="no column named fact"):
        _ = edge_fulltext_search(edges, "a", 3)
    with assert_raises(contains="no column named src_nid"):
        _ = edge_out_degree(edges, 1)


def test_a_column_of_the_wrong_type_is_refused() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field("src_nid", ArrowType.STRING, False))
    sb.add_field(Field("fact", ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    var ids: List[Int64] = [1, 2]
    rb.add_column(_strs(["1", "2"]))
    rb.add_column(_ints(ids))
    var edges = _write(_one("edges", rb.build(sb.build()), 1), 4)
    with assert_raises(contains="not a string column"):
        _ = edge_fulltext_search(edges, "a", 3)
    with assert_raises(contains="not INT64"):
        _ = edge_out_degree(edges, 1)


def test_columns_are_found_by_name_not_position() raises:
    # The embedding column first, then an extra column, then nid.
    var rows: List[List[Float64]] = [[1.0, 0.0], [0.0, 1.0], [1.0, 1.0]]
    var sb = SchemaBuilder()
    sb.add_field(Field("name_embedding", ArrowType.LARGE_STRING, False))
    sb.add_field(Field("extra", ArrowType.STRING, False))
    sb.add_field(Field("nid", ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    var ids: List[Int64] = [0, 1, 2]
    rb.add_column(_strs(_packed(rows)))
    rb.add_column(_strs(_repeat("x", 3)))
    rb.add_column(_ints(ids))
    var view = _write(_one("entities", rb.build(sb.build()), 1), 2)
    var query: List[Float64] = [0.0, 1.0]
    _assert_rows(node_similarity_search(view, query, 3), [1, 2, 0])

    var esb = SchemaBuilder()
    esb.add_field(Field("fact", ArrowType.LARGE_STRING, False))
    esb.add_field(Field("src_nid", ArrowType.INT64, False))
    var erb = RecordBatchBuilder()
    var src: List[Int64] = [4, 4, 9]
    erb.add_column(_strs(["go go", "no", "go"]))
    erb.add_column(_ints(src))
    var edges = _write(_one("edges", erb.build(esb.build()), 1), 2)
    _assert_rows(edge_fulltext_search(edges, "go", 5), [0, 2])
    assert_equal(edge_out_degree(edges, 4), 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
