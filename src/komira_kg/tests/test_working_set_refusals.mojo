# =============================================================================
# test_working_set_refusals.mojo -- what the working set refuses: a wrong
#   embedding dimension, and tables from storage that are malformed (an
#   in-memory object store; no network, no clock, no environment).
# =============================================================================
#
#   dimension     a set made with dimension zero or less is refused; an entity
#                 added with an embedding of another length, or with a component
#                 that is NaN, an infinity or beyond the f32 range, is refused; a
#                 vector changed in place to a wrong length is refused when the
#                 tables are written; a snapshot whose manifest records another
#                 dimension than its embedding cells holds is refused on load;
#                 so is a delta whose cells have another dimension than the
#                 base's.
#   ids           an entity added with a negative id or with Int64.MAX is refused;
#                 a table with a repeated node id, a negative one or Int64.MAX is
#                 refused on load; two entities sharing an id are refused when
#                 written; adding an entity with a larger id raises the id the
#                 next mint returns.
#   storage       a table stamped with a schema version newer than this build is
#                 refused; a table with too few columns, or a column of the wrong
#                 type, is refused; a delta tombstone that matches no edge is
#                 refused, and so is one that matches two open edges (a delta
#                 cannot say which to close).
#   cells         a text cell that is not UTF-8 and a null cell in a required
#                 column are refused, and the same table with a real value loads;
#                 a delta table stamped newer than this build is refused.
#   decode        a text column holding integers, a null integer cell and a null
#                 embedding cell are refused; a delta index outside the chain
#                 is refused; a delta whose entities table repeats a node id is
#                 refused on load.
#   id space      a mint at Int64.MAX is refused, and refused again.
#   shrunk set    tombstone_edge_indices of a set with fewer edges than loaded
#                 reports only the edges still held.
#   delta guard   a set whose edges or episodes shrank below their loaded count
#                 cannot write a delta.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab
from komira_kg import (
    SnapshotWorkingSet,
    WorkingEntity,
    WorkingEpisode,
    open_edge,
)
from komira_kg.working_codec import (
    decode_edge_closures,
    decode_entities,
    decode_episodes,
    read_delta_table,
)
from komira_kg_format import (
    KgNameIndexBody,
    KgSnapshotStore,
    KgTable,
    SCHEMA_VERSION_EDGES,
    SCHEMA_VERSION_ENTITIES,
    edges_tombstone_schema,
    entities_schema,
    pack_embedding,
)
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

comptime Backend = SharedInMemoryConditionalStore
comptime Kg = KgSnapshotStore[SharedInMemoryConditionalStore]


def _vec(dim: Int) -> List[Float64]:
    var v = List[Float64]()
    for i in range(dim):
        v.append(Float64(i) * 0.5)
    return v^


def _ent(nid: Int64, dim: Int) -> WorkingEntity:
    return WorkingEntity(nid, "u", "p", "n" + String(nid), _vec(dim), "", "{}")


def _set(dim: Int) raises -> SnapshotWorkingSet:
    var ws = SnapshotWorkingSet(dim)
    ws.add_entity(_ent(ws.next_nid(), dim))
    ws.add_entity(_ent(ws.next_nid(), dim))
    ws.add_edge(open_edge(0, 1, "", "a fact", 1, 2, 1))
    ws.append_episode(WorkingEpisode("e", "p", "text", 2, 1))
    return ws^


def _i64(values: List[Int64]) -> Column[HeapRegion]:
    return Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(values)
    )


def _one(v: Int64) -> List[Int64]:
    var out = List[Int64]()
    out.append(v)
    return out^


def _strs(values: List[String]) raises -> Column[HeapRegion]:
    return Column.from_string(StringArray.from_strings(values))


def _entities_table(
    nids: List[Int64], dim: Int, version: Int64 = SCHEMA_VERSION_ENTITIES
) raises -> Slab[KgTable]:
    """An entities table with the given node ids and `dim`-component cells."""
    var uuids = List[String]()
    var parts = List[String]()
    var names = List[String]()
    var embs = List[String]()
    var empty = List[String]()
    var attrs = List[String]()
    for i in range(len(nids)):
        uuids.append("u" + String(i))
        parts.append("p")
        names.append("n" + String(i))
        embs.append(pack_embedding(_vec(dim)))
        empty.append("")
        attrs.append("{}")
    var rb = RecordBatchBuilder()
    rb.add_column(_i64(nids))
    rb.add_column(_strs(uuids))
    rb.add_column(_strs(parts))
    rb.add_column(_strs(names))
    rb.add_column(_strs(embs))
    rb.add_column(_strs(empty))
    rb.add_column(_strs(attrs))
    var out = Slab[KgTable]()
    out.append(KgTable("entities", rb.build(entities_schema()), version))
    return out^


def test_dimension_must_be_positive() raises:
    with assert_raises(contains="dimension must be positive"):
        _ = SnapshotWorkingSet(0)
    with assert_raises(contains="dimension must be positive"):
        _ = SnapshotWorkingSet(-3)


def test_entity_of_another_dimension_is_refused() raises:
    var ws = SnapshotWorkingSet(3)
    with assert_raises(contains="2 components but the graph's dimension is 3"):
        ws.add_entity(_ent(0, 2))
    with assert_raises(contains="4 components but the graph's dimension is 3"):
        ws.add_entity(_ent(0, 4))
    assert_equal(ws.num_entities(), 0)


def test_non_finite_components_are_refused() raises:
    var ws = SnapshotWorkingSet(2)
    var nan = _vec(2)
    nan[1] = Float64.MAX - Float64.MAX  # 0.0, replaced below
    nan[1] = nan[1] / nan[1]
    with assert_raises(contains="not a finite f32"):
        ws.add_entity(WorkingEntity(0, "u", "p", "n", nan^, "", "{}"))
    var huge = _vec(2)
    huge[0] = 1.0e300
    with assert_raises(contains="not a finite f32"):
        ws.add_entity(WorkingEntity(0, "u", "p", "n", huge^, "", "{}"))


def test_vector_changed_to_a_wrong_length_is_refused_on_write() raises:
    var ws = _set(3)
    ws.entities[1].name_embedding = _vec(2)
    with assert_raises(contains="2 components but the graph's dimension is 3"):
        _ = ws.to_tables()
    with assert_raises(contains="2 components but the graph's dimension is 3"):
        _ = ws.delta_tables()


def test_manifest_dimension_is_held_on_load() raises:
    var ws = _set(3)
    var kg = Kg(Backend(), "g")
    # The cells hold 3 components; the manifest says 4.
    _ = kg.write_snapshot(ws.to_tables(), 4)
    with assert_raises(contains="which is not a dimension of 4"):
        _ = SnapshotWorkingSet.load_latest(kg)


def test_delta_of_another_dimension_is_refused() raises:
    var kg = Kg(Backend(), "g")
    var base = _set(3)
    _ = kg.write_snapshot(base.to_tables(), 3)
    var other = SnapshotWorkingSet(2)
    other.add_entity(_ent(other.next_nid(), 2))
    _ = kg.append_delta(other.delta_tables(), KgNameIndexBody())
    with assert_raises(contains="which is not a dimension of 3"):
        _ = SnapshotWorkingSet.load_latest(kg)


def test_node_id_range_is_held_on_add() raises:
    var ws = SnapshotWorkingSet(2)
    with assert_raises(contains="out of range"):
        ws.add_entity(_ent(-1, 2))
    with assert_raises(contains="out of range"):
        ws.add_entity(_ent(Int64.MAX, 2))
    assert_equal(ws.num_entities(), 0)


def test_larger_id_raises_the_mint() raises:
    var ws = SnapshotWorkingSet(2)
    ws.add_entity(_ent(40, 2))
    assert_equal(ws.next_nid(), 41)


def test_node_ids_are_held_on_load() raises:
    var cases = List[List[Int64]]()
    cases.append([0, 1, 0])
    cases.append([0, -1])
    cases.append([Int64.MAX])
    var wants = List[String]()
    wants.append("repeats node id 0")
    wants.append("out of range")
    wants.append("out of range")
    for i in range(len(cases)):
        var kg = Kg(Backend(), "g")
        _ = kg.write_snapshot(_entities_table(cases[i], 2), 2)
        with assert_raises(contains=wants[i]):
            _ = SnapshotWorkingSet.load_latest(kg)


def test_two_entities_with_one_id_are_refused_on_write() raises:
    var ws = SnapshotWorkingSet(2)
    ws.add_entity(_ent(0, 2))
    ws.entities.append(_ent(0, 2))
    with assert_raises(contains="share node id 0"):
        _ = ws.to_tables()


def test_schema_version_newer_than_the_build_is_refused() raises:
    var kg = Kg(Backend(), "g")
    _ = kg.write_snapshot(
        _entities_table([0, 1], 2, SCHEMA_VERSION_ENTITIES + 1), 2
    )
    with assert_raises(contains="schema_version"):
        _ = SnapshotWorkingSet.load_latest(kg)


def test_table_with_too_few_columns_is_refused() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field("nid", ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    var nids = List[Int64]()
    nids.append(0)
    rb.add_column(_i64(nids))
    var tables = Slab[KgTable]()
    tables.append(KgTable("entities", rb.build(sb.build()), SCHEMA_VERSION_ENTITIES))
    var kg = Kg(Backend(), "g")
    _ = kg.write_snapshot(tables^, 2)
    with assert_raises(contains="has 1 columns, expected at least 7"):
        _ = SnapshotWorkingSet.load_latest(kg)


def test_column_of_the_wrong_type_is_refused() raises:
    # An episodes table whose ts column holds strings.
    var sb = SchemaBuilder()
    sb.add_field(Field("uuid", ArrowType.STRING, False))
    sb.add_field(Field("partition_id", ArrowType.STRING, False))
    sb.add_field(Field("body", ArrowType.STRING, False))
    sb.add_field(Field("ts", ArrowType.STRING, False))
    sb.add_field(Field("valid_at", ArrowType.INT64, False))
    sb.add_field(Field("facet", ArrowType.STRING, False))
    var one = List[String]()
    one.append("x")
    var ints = List[Int64]()
    ints.append(1)
    var rb = RecordBatchBuilder()
    rb.add_column(_strs(one))
    rb.add_column(_strs(one))
    rb.add_column(_strs(one))
    rb.add_column(_strs(one))
    rb.add_column(_i64(ints))
    rb.add_column(_strs(one))
    var tables = Slab[KgTable]()
    tables.append(KgTable("episodes", rb.build(sb.build()), 1))
    var kg = Kg(Backend(), "g")
    _ = kg.write_snapshot(tables^, 2)
    with assert_raises(contains="column 3 is not INT64"):
        _ = SnapshotWorkingSet.load_latest(kg)


def _episodes_table(
    body: String, body_valid: Bool, nullable_body: Bool
) raises -> Slab[KgTable]:
    """A one-row episodes table whose body cell is `body`, or null."""
    var sb = SchemaBuilder()
    sb.add_field(Field("uuid", ArrowType.STRING, False))
    sb.add_field(Field("partition_id", ArrowType.STRING, False))
    sb.add_field(Field("body", ArrowType.STRING, nullable_body))
    sb.add_field(Field("ts", ArrowType.INT64, False))
    sb.add_field(Field("valid_at", ArrowType.INT64, False))
    sb.add_field(Field("facet", ArrowType.STRING, False))
    var one = List[String]()
    one.append("x")
    var bodies = List[String]()
    bodies.append(body)
    var valid = List[Bool]()
    valid.append(body_valid)
    var ints = List[Int64]()
    ints.append(1)
    var rb = RecordBatchBuilder()
    rb.add_column(_strs(one))
    rb.add_column(_strs(one))
    rb.add_column(
        Column.from_string(
            StringArray.from_strings_with_validity(bodies, valid)
        )
    )
    rb.add_column(_i64(ints))
    rb.add_column(_i64(ints))
    rb.add_column(_strs(one))
    var tables = Slab[KgTable]()
    tables.append(KgTable("episodes", rb.build(sb.build()), 1))
    return tables^


def test_text_that_is_not_utf8_is_refused() raises:
    var bad = List[UInt8]()
    bad.append(0x61)
    bad.append(0xFF)  # never valid in UTF-8
    bad.append(0x62)
    # SAFETY (test): builds the invalid text on purpose, to be refused by the
    # reader.
    var text = String(StringSlice(unsafe_from_utf8=Span(bad)))
    var kg = Kg(Backend(), "g")
    _ = kg.write_snapshot(_episodes_table(text, True, False), 2)
    with assert_raises(contains="not UTF-8"):
        _ = SnapshotWorkingSet.load_latest(kg)


def test_null_cell_is_refused() raises:
    var kg = Kg(Backend(), "g")
    _ = kg.write_snapshot(_episodes_table("", False, True), 2)
    with assert_raises(contains="null cell"):
        _ = SnapshotWorkingSet.load_latest(kg)
    # The same table with a real value loads.
    var ok = Kg(Backend(), "g")
    _ = ok.write_snapshot(_episodes_table("fine", True, False), 2)
    var ws = SnapshotWorkingSet.load_latest(ok)
    assert_equal(ws.episodes[0].body, "fine")


def test_delta_table_newer_than_the_build_is_refused() raises:
    var kg = Kg(Backend(), "g")
    _ = kg.write_snapshot(_set(2).to_tables(), 2)
    var ws = SnapshotWorkingSet.load_latest(kg)
    ws.append_episode(WorkingEpisode("e2", "p", "more", 3, 2))
    var tables = ws.delta_tables()
    var newer = Slab[KgTable]()
    newer.append(KgTable("episodes", tables[0].take_batch(), 2))
    _ = kg.append_delta(newer^, KgNameIndexBody())
    with assert_raises(contains="reader-supported"):
        _ = SnapshotWorkingSet.load_latest(kg)


def test_tombstone_without_an_edge_is_refused() raises:
    var kg = Kg(Backend(), "g")
    var base = _set(2)
    _ = kg.write_snapshot(base.to_tables(), 2)
    var ws = SnapshotWorkingSet.load_latest(kg)
    ws.edges[0].invalid_at = 5
    ws.edges[0].expired_at = 6
    # Corrupt the key the tombstone will carry: the edge was created at 2.
    ws.edges[0].created_at = 999
    _ = kg.append_delta(ws.delta_tables(), KgNameIndexBody())
    with assert_raises(contains="matches no edge"):
        _ = SnapshotWorkingSet.load_latest(kg)


def test_tombstone_matching_two_open_edges_is_refused_on_load() raises:
    var kg = Kg(Backend(), "g")
    var base = _set(2)
    # A second edge with the same (src, dst, created_at) as the first.
    base.add_edge(open_edge(0, 1, "", "a twin fact", 5, 2, 1))
    _ = kg.write_snapshot(base.to_tables(), 2)
    # The delta is built by hand: the working set refuses to write it.
    var rb = RecordBatchBuilder()
    rb.add_column(_i64(_one(0)))
    rb.add_column(_i64(_one(1)))
    rb.add_column(_i64(_one(2)))
    rb.add_column(_i64(_one(50)))
    rb.add_column(_i64(_one(60)))
    var tables = Slab[KgTable]()
    tables.append(
        KgTable(
            "edges_tombstone",
            rb.build(edges_tombstone_schema()),
            SCHEMA_VERSION_EDGES,
        )
    )
    _ = kg.append_delta(tables^, KgNameIndexBody())
    with assert_raises(contains="ambiguous"):
        _ = SnapshotWorkingSet.load_latest(kg)


def test_delta_of_a_shrunk_set_is_refused() raises:
    var kg = Kg(Backend(), "g")
    _ = kg.write_snapshot(_set(2).to_tables(), 2)
    var ws = SnapshotWorkingSet.load_latest(kg)
    _ = ws.edges.pop()
    with assert_raises(contains="edge list shrank"):
        _ = ws.delta_tables()
    var ws2 = SnapshotWorkingSet.load_latest(kg)
    _ = ws2.episodes.pop()
    with assert_raises(contains="episode list shrank"):
        _ = ws2.delta_tables()
    # A full snapshot of the shrunk set is still writable.
    assert_true(len(ws2.to_tables()) > 0)


def test_text_column_holding_integers_is_refused() raises:
    # An episodes table whose uuid column (a text column) holds integers.
    var sb = SchemaBuilder()
    sb.add_field(Field("uuid", ArrowType.INT64, False))
    sb.add_field(Field("partition_id", ArrowType.STRING, False))
    sb.add_field(Field("body", ArrowType.STRING, False))
    sb.add_field(Field("ts", ArrowType.INT64, False))
    sb.add_field(Field("valid_at", ArrowType.INT64, False))
    sb.add_field(Field("facet", ArrowType.STRING, False))
    var one = List[String]()
    one.append("x")
    var rb = RecordBatchBuilder()
    rb.add_column(_i64(_one(7)))
    rb.add_column(_strs(one))
    rb.add_column(_strs(one))
    rb.add_column(_i64(_one(1)))
    rb.add_column(_i64(_one(1)))
    rb.add_column(_strs(one))
    with assert_raises(
        contains="table episodes: column 0 is not a string column"
    ):
        _ = decode_episodes(rb.build(sb.build()))


def test_null_integer_cell_is_refused() raises:
    # A tombstone batch whose created_at cell is null.
    var created = PrimitiveArray[DType.int64].allocate_nullable(1)
    created.set(0, 5)
    created._set_null(0)
    var rb = RecordBatchBuilder()
    rb.add_column(_i64(_one(0)))
    rb.add_column(_i64(_one(1)))
    rb.add_column(Column.from_primitive[DType.int64](created^))
    rb.add_column(_i64(_one(50)))
    rb.add_column(_i64(_one(60)))
    with assert_raises(
        contains="table edges_tombstone: null cell in a required column, row 0"
    ):
        _ = decode_edge_closures(rb.build(edges_tombstone_schema()))
    # The same row with every cell present decodes.
    var ok = RecordBatchBuilder()
    ok.add_column(_i64(_one(0)))
    ok.add_column(_i64(_one(1)))
    ok.add_column(_i64(_one(5)))
    ok.add_column(_i64(_one(50)))
    ok.add_column(_i64(_one(60)))
    var rows = decode_edge_closures(ok.build(edges_tombstone_schema()))
    assert_equal(len(rows), 1)
    assert_equal(rows[0].created_at, 5)


def test_null_embedding_cell_is_refused() raises:
    var one = List[String]()
    one.append("x")
    var cells = List[String]()
    cells.append(pack_embedding(_vec(2)))
    var valid = List[Bool]()
    valid.append(False)
    var sb = SchemaBuilder()
    sb.add_field(Field("nid", ArrowType.INT64, False))
    sb.add_field(Field("uuid", ArrowType.STRING, False))
    sb.add_field(Field("partition_id", ArrowType.STRING, False))
    sb.add_field(Field("name", ArrowType.STRING, False))
    sb.add_field(Field("name_embedding", ArrowType.STRING, True))
    sb.add_field(Field("summary", ArrowType.STRING, False))
    sb.add_field(Field("attrs", ArrowType.STRING, False))
    var rb = RecordBatchBuilder()
    rb.add_column(_i64(_one(0)))
    rb.add_column(_strs(one))
    rb.add_column(_strs(one))
    rb.add_column(_strs(one))
    rb.add_column(
        Column.from_string(StringArray.from_strings_with_validity(cells, valid))
    )
    rb.add_column(_strs(one))
    rb.add_column(_strs(one))
    with assert_raises(contains="table entities: null embedding cell, row 0"):
        _ = decode_entities(rb.build(sb.build()), 2)


def test_delta_index_out_of_range_is_refused() raises:
    var kg = Kg(Backend(), "g")
    _ = kg.write_snapshot(_set(2).to_tables(), 2)
    var chain = kg.open_latest_chain()
    # A base alone has no delta 0, and no negative one.
    with assert_raises(contains="delta index 0 out of range"):
        _ = read_delta_table(chain, 0, "episodes", 1)
    with assert_raises(contains="delta index -1 out of range"):
        _ = read_delta_table(chain, -1, "episodes", 1)


def test_delta_repeating_a_node_id_is_refused() raises:
    var kg = Kg(Backend(), "g")
    _ = kg.write_snapshot(_set(2).to_tables(), 2)
    _ = kg.append_delta(_entities_table([7, 7], 2), KgNameIndexBody())
    with assert_raises(
        contains="delta 0: entities table repeats node id 7"
    ):
        _ = SnapshotWorkingSet.load_latest(kg)


def test_node_ids_can_run_out() raises:
    var ws = SnapshotWorkingSet(2)
    ws._high_water = Int64.MAX
    with assert_raises(contains="node ids exhausted"):
        _ = ws.next_nid()
    # The refusal mints nothing: the same call refuses again.
    with assert_raises(contains="node ids exhausted"):
        _ = ws.next_nid()


def test_a_shrunk_set_reports_only_the_edges_it_still_holds() raises:
    var kg = Kg(Backend(), "g")
    var base = _set(2)
    base.add_edge(open_edge(0, 1, "", "second fact", 3, 4, 3))
    _ = kg.write_snapshot(base.to_tables(), 2)
    var ws = SnapshotWorkingSet.load_latest(kg)
    ws.edges[0].invalid_at = 9
    ws.edges[0].expired_at = 10
    _ = ws.edges.pop()
    var closed = ws.tombstone_edge_indices()
    assert_equal(len(closed), 1)
    assert_equal(closed[0], 0)
    # With every loaded edge gone there is nothing left to report.
    _ = ws.edges.pop()
    assert_equal(len(ws.tombstone_edge_indices()), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
