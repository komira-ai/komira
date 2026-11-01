# =============================================================================
# test_embedding_topk.mojo -- the nearest entities to a vector, from the deltas'
#   embedding projection (an in-memory object store; no network, no clock, no
#   environment).
# =============================================================================
#
#   exact         on stated vectors the k nearest by cosine come back with their
#                 scores, for k below, at and above the number of entities. The
#                 scores equal `cosine` of the reloaded entity vectors.
#   tie order     equal scores are ordered by ascending node id, whatever order
#                 the rows were written in (node ids 10 and 7 tie with 10 first
#                 in the rows).
#   later wins    an entity re-embedded in a later delta is ranked by its new
#                 vector, once.
#   nothing       a base alone, and deltas that carry no projection, give no
#                 candidates.
#   refusals      k of zero or less, a query shorter or longer than the graph's
#                 dimension, a query with a NaN or infinite component, and a
#                 projection cell of another dimension.
#   non-finite    a stored row with a NaN or infinite component (written past the
#                 working set) is skipped, never ranked, whether it is the
#                 entity's only row or replaces a finite one.
#   heap          on 24 entities whose scores are only 1, 0 and -1 (so almost
#                 every pair ties) the answer equals a full sort by score
#                 descending, node id ascending, for k below, at and above the
#                 number of rows.
#   decode        a projection batch decodes to its ids and vectors; a null
#                 cell, an id out of range and a column of the wrong type are
#                 refused.
# =============================================================================

from std.math import inf, nan
from std.testing import (
    TestSuite,
    assert_almost_equal,
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
from komira_collections.slab import Slab
from komira_kg import (
    SnapshotWorkingSet,
    WorkingEntity,
    open_edge,
    resolve_embedding_topk,
)
from komira_kg.working_codec import (
    TABLE_ENTITIES_EMBEDDING,
    build_embedding_projection_batch,
    decode_embedding_projection,
)
from komira_kg_format import (
    KgNameIndexBody,
    KgSnapshotStore,
    KgTable,
    SCHEMA_VERSION_ENTITIES_EMBEDDING,
    cosine,
    pack_embedding,
)
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

comptime Backend = SharedInMemoryConditionalStore
comptime Kg = KgSnapshotStore[SharedInMemoryConditionalStore]
comptime DIM = 2


def _vec(a: Float64, b: Float64) -> List[Float64]:
    var v = List[Float64]()
    v.append(a)
    v.append(b)
    return v^


def _ent(nid: Int64, name: String, a: Float64, b: Float64) -> WorkingEntity:
    return WorkingEntity(nid, "u-" + String(nid), "p", name, _vec(a, b), "", "{}")


def _append(mut kg: Kg, ws: SnapshotWorkingSet) raises:
    _ = kg.append_delta(ws.delta_tables(), ws.name_index_delta())


def _store() raises -> Kg:
    """A base entity 0, then two deltas adding nids 10 and 3, then 7, 5 and 8."""
    var kg = Kg(Backend(), "g")
    var base = SnapshotWorkingSet(DIM)
    base.add_entity(_ent(base.next_nid(), "base", 1.0, 0.0))
    _ = kg.write_snapshot(base.to_tables(), DIM)

    var d1 = SnapshotWorkingSet.load_latest(kg)
    d1.add_entity(_ent(10, "x", 2.0, 0.0))
    d1.add_entity(_ent(3, "y", 0.0, 1.0))
    _append(kg, d1)

    var d2 = SnapshotWorkingSet.load_latest(kg)
    d2.add_entity(_ent(7, "z", 1.0, 0.0))
    d2.add_entity(_ent(5, "w", -1.0, 0.0))
    d2.add_entity(_ent(8, "v", 1.0, 1.0))
    _append(kg, d2)
    return kg^


def test_the_k_nearest_come_back_by_cosine_with_their_scores() raises:
    var kg = _store()
    var chain = kg.open_latest_chain()
    var q = _vec(1.0, 0.0)

    var three = resolve_embedding_topk(chain, q, 3)
    assert_equal(len(three), 3)
    assert_equal(three[0].nid, 7)
    assert_equal(three[0].score, 1.0)
    assert_equal(three[1].nid, 10)
    assert_equal(three[1].score, 1.0)
    assert_equal(three[2].nid, 8)
    assert_almost_equal(three[2].score, 0.7071067811865476, atol=1e-12)

    var one = resolve_embedding_topk(chain, q, 1)
    assert_equal(len(one), 1)
    assert_equal(one[0].nid, 7)

    # The base entity is in no projection; the five delta entities are.
    var all = resolve_embedding_topk(chain, q, 5)
    assert_equal(len(all), 5)
    assert_equal(all[3].nid, 3)
    assert_equal(all[3].score, 0.0)
    assert_equal(all[4].nid, 5)
    assert_equal(all[4].score, -1.0)
    assert_equal(len(resolve_embedding_topk(chain, q, 500)), 5)

    # Every score is the cosine of the vector a reload holds.
    var ws = SnapshotWorkingSet.load_latest(kg)
    for i in range(len(all)):
        var at = ws.entity_index_of_nid(all[i].nid)
        assert_true(at >= 0)
        assert_equal(all[i].score, cosine(q, ws.entities[at].name_embedding))


def test_equal_scores_are_ordered_by_ascending_node_id() raises:
    var kg = _store()
    var chain = kg.open_latest_chain()
    # A zero query scores every row 0.0: the order is the node ids.
    var zero = resolve_embedding_topk(chain, _vec(0.0, 0.0), 5)
    var expected = List[Int64]()
    expected.append(3)
    expected.append(5)
    expected.append(7)
    expected.append(8)
    expected.append(10)
    assert_equal(len(zero), 5)
    for i in range(5):
        assert_equal(zero[i].nid, expected[i])
        assert_equal(zero[i].score, 0.0)
    # The first two of three tied at 1.0 are 7 and 10, though 10 was written
    # first; k cuts the tie by node id.
    var two = resolve_embedding_topk(chain, _vec(1.0, 0.0), 2)
    assert_equal(two[0].nid, 7)
    assert_equal(two[1].nid, 10)


def test_an_entity_re_embedded_by_a_later_delta_counts_once_by_its_new_vector() raises:
    var kg = _store()
    var d3 = SnapshotWorkingSet.load_latest(kg)
    var at = d3.entity_index_of_nid(7)
    d3.entities[at].name_embedding = _vec(0.0, -1.0)
    _append(kg, d3)

    var all = resolve_embedding_topk(kg.open_latest_chain(), _vec(1.0, 0.0), 10)
    assert_equal(len(all), 5)
    var order = List[Int64]()
    order.append(10)  # 1.0
    order.append(8)  # 0.7071...
    order.append(3)  # 0.0, ties by node id
    order.append(7)  # 0.0, re-embedded
    order.append(5)  # -1.0
    for i in range(5):
        assert_equal(all[i].nid, order[i])
    assert_equal(all[3].score, 0.0)


def test_a_base_alone_and_deltas_without_a_projection_give_no_candidates() raises:
    var kg = Kg(Backend(), "g")
    var base = SnapshotWorkingSet(DIM)
    base.add_entity(_ent(base.next_nid(), "base", 1.0, 0.0))
    _ = kg.write_snapshot(base.to_tables(), DIM)
    assert_equal(len(resolve_embedding_topk(kg.open_latest_chain(), _vec(1.0, 0.0), 3)), 0)

    var edge = SnapshotWorkingSet.load_latest(kg)
    edge.add_edge(open_edge(0, 0, "", "self", 1, 2, 1))
    _append(kg, edge)
    var chain = kg.open_latest_chain()
    assert_equal(chain.num_deltas(), 1)
    assert_equal(len(resolve_embedding_topk(chain, _vec(1.0, 0.0), 3)), 0)


def test_k_of_zero_or_less_and_a_query_of_the_wrong_dimension_are_refused() raises:
    var kg = _store()
    var chain = kg.open_latest_chain()
    with assert_raises(contains="k must be positive, got 0"):
        _ = resolve_embedding_topk(chain, _vec(1.0, 0.0), 0)
    with assert_raises(contains="k must be positive, got -4"):
        _ = resolve_embedding_topk(chain, _vec(1.0, 0.0), -4)
    var short = List[Float64]()
    short.append(1.0)
    with assert_raises(contains="1 components but the graph's dimension is 2"):
        _ = resolve_embedding_topk(chain, short, 3)
    var long = _vec(1.0, 0.0)
    long.append(0.5)
    with assert_raises(contains="3 components but the graph's dimension is 2"):
        _ = resolve_embedding_topk(chain, long, 3)
    # The refusal comes before any table is read: a base alone refuses too.
    var alone = Kg(Backend(), "h")
    var base = SnapshotWorkingSet(DIM)
    base.add_entity(_ent(base.next_nid(), "base", 1.0, 0.0))
    _ = alone.write_snapshot(base.to_tables(), DIM)
    with assert_raises(contains="k must be positive"):
        _ = resolve_embedding_topk(alone.open_latest_chain(), _vec(1.0, 0.0), 0)


def test_a_projection_cell_of_another_dimension_is_refused() raises:
    var kg = _store()
    # Three components written into a graph of two.
    var wide = List[WorkingEntity]()
    var v = List[Float64]()
    v.append(1.0)
    v.append(0.0)
    v.append(0.5)
    wide.append(WorkingEntity(20, "u-20", "p", "wide", v^, "", "{}"))
    var idxs = List[Int]()
    idxs.append(0)
    var tables = Slab[KgTable]()
    tables.append(
        KgTable(
            String(TABLE_ENTITIES_EMBEDDING),
            build_embedding_projection_batch(wide, idxs, 3),
            SCHEMA_VERSION_ENTITIES_EMBEDDING,
        )
    )
    _ = kg.append_delta(tables^, KgNameIndexBody())
    with assert_raises(contains="which is not a dimension of 2"):
        _ = resolve_embedding_topk(kg.open_latest_chain(), _vec(1.0, 0.0), 3)


def _raw_projection(nids: List[Int64], vectors: List[List[Float64]]) raises -> RecordBatch:
    """A projection batch written past the working set, which refuses a vector
    that is not finite."""
    var cells = List[String]()
    for i in range(len(vectors)):
        cells.append(pack_embedding(vectors[i]))
    var sb = SchemaBuilder()
    sb.add_field(Field("nid", ArrowType.INT64, False))
    sb.add_field(Field("name_embedding", ArrowType.STRING, True))
    var rb = RecordBatchBuilder()
    rb.add_column(
        Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(nids))
    )
    rb.add_column(Column.from_string(StringArray.from_strings(cells)))
    return rb.build(sb.build())


def _append_raw(mut kg: Kg, nids: List[Int64], vectors: List[List[Float64]]) raises:
    var tables = Slab[KgTable]()
    tables.append(
        KgTable(
            String(TABLE_ENTITIES_EMBEDDING),
            _raw_projection(nids, vectors),
            SCHEMA_VERSION_ENTITIES_EMBEDDING,
        )
    )
    _ = kg.append_delta(tables^, KgNameIndexBody())


def test_a_query_with_a_non_finite_component_is_refused() raises:
    var kg = _store()
    var chain = kg.open_latest_chain()
    with assert_raises(contains="query component 0 is not finite"):
        _ = resolve_embedding_topk(chain, _vec(nan[DType.float64](), 0.0), 3)
    with assert_raises(contains="query component 1 is not finite"):
        _ = resolve_embedding_topk(chain, _vec(1.0, inf[DType.float64]()), 3)
    with assert_raises(contains="query component 1 is not finite"):
        _ = resolve_embedding_topk(chain, _vec(1.0, -inf[DType.float64]()), 3)


def test_a_stored_row_with_a_non_finite_component_is_skipped() raises:
    var kg = _store()
    var nids = List[Int64]()
    var vectors = List[List[Float64]]()
    nids.append(20)  # a new entity with a NaN
    vectors.append(_vec(nan[DType.float64](), 0.0))
    nids.append(21)  # a new entity with an infinity
    vectors.append(_vec(1.0, inf[DType.float64]()))
    nids.append(7)  # replaces the finite row of 7 (1, 0), which scored 1.0
    vectors.append(_vec(nan[DType.float64](), nan[DType.float64]()))
    _append_raw(kg, nids, vectors)

    # cosine scores such rows 0.0, level with the genuine orthogonal ones; they
    # are not ranked at all, so only the four other finite rows remain.
    var all = resolve_embedding_topk(kg.open_latest_chain(), _vec(1.0, 0.0), 10)
    assert_equal(len(all), 4)
    var expected = List[Int64]()
    expected.append(10)  # 1.0
    expected.append(8)  # 0.7071...
    expected.append(3)  # 0.0
    expected.append(5)  # -1.0
    for i in range(4):
        assert_equal(all[i].nid, expected[i])
    var zero = resolve_embedding_topk(kg.open_latest_chain(), _vec(0.0, 0.0), 10)
    assert_equal(len(zero), 4)


def _dataset_store() raises -> Kg:
    """24 entities with node ids in a scrambled order. Their vectors lie on the
    axes, so each scores exactly 1, 0 or -1 against (1, 0) and most pairs tie;
    four are diagonal and one is zero."""
    var kg = Kg(Backend(), "g")
    var base = SnapshotWorkingSet(DIM)
    base.add_entity(_ent(base.next_nid(), "base", 0.0, 1.0))
    _ = kg.write_snapshot(base.to_tables(), DIM)
    var ws = SnapshotWorkingSet.load_latest(kg)
    for i in range(24):
        var nid = Int64(100 + (i * 7) % 24)
        var kind = i % 6
        var scale = Float64(1 + i % 3)
        if kind == 0:
            ws.add_entity(_ent(nid, "e" + String(i), scale, 0.0))
        elif kind == 1:
            ws.add_entity(_ent(nid, "e" + String(i), 0.0, scale))
        elif kind == 2:
            ws.add_entity(_ent(nid, "e" + String(i), -scale, 0.0))
        elif kind == 3:
            ws.add_entity(_ent(nid, "e" + String(i), scale, scale))
        elif kind == 4:
            ws.add_entity(_ent(nid, "e" + String(i), 0.0, -scale))
        else:
            ws.add_entity(_ent(nid, "e" + String(i), 0.0, 0.0))
    _append(kg, ws)
    return kg^


def test_the_heap_agrees_with_a_full_sort_on_ties_for_every_k() raises:
    var kg = _dataset_store()
    var chain = kg.open_latest_chain()
    var q = _vec(1.0, 0.0)
    var ws = SnapshotWorkingSet.load_latest(kg)
    # The projection holds the 24 delta entities, not the base one.
    var nids = List[Int64]()
    var scores = List[Float64]()
    for i in range(len(ws.entities)):
        if ws.entities[i].nid >= 100:
            nids.append(ws.entities[i].nid)
            scores.append(cosine(q, ws.entities[i].name_embedding))
    assert_equal(len(nids), 24)
    # Brute force: selection sort by score descending, node id ascending.
    var order = List[Int]()
    for i in range(24):
        order.append(i)
    for i in range(24):
        var best = i
        for j in range(i + 1, 24):
            var a = order[j]
            var b = order[best]
            if scores[a] > scores[b] or (scores[a] == scores[b] and nids[a] < nids[b]):
                best = j
        var held = order[i]
        order[i] = order[best]
        order[best] = held

    var ks = List[Int]()
    ks.append(1)
    ks.append(2)
    ks.append(3)
    ks.append(5)
    ks.append(8)
    ks.append(13)
    ks.append(23)
    ks.append(24)
    ks.append(25)
    ks.append(500)
    for t in range(len(ks)):
        var k = ks[t]
        var got = resolve_embedding_topk(chain, q, k)
        var want = min(k, 24)
        assert_equal(len(got), want)
        for i in range(want):
            assert_equal(got[i].nid, nids[order[i]])
            assert_equal(got[i].score, scores[order[i]])


def _projection(nid: Int64, null_cell: Bool, nid_as_text: Bool) raises -> RecordBatch:
    """A one-row projection batch: a null embedding cell, or a node id column of
    the wrong type, on request."""
    var cells = List[String]()
    cells.append(pack_embedding(_vec(1.0, 0.0)))
    var valid = List[Bool]()
    valid.append(not null_cell)
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    if nid_as_text:
        sb.add_field(Field("nid", ArrowType.STRING, False))
        var ids = List[String]()
        ids.append("0")
        rb.add_column(Column.from_string(StringArray.from_strings(ids)))
    else:
        sb.add_field(Field("nid", ArrowType.INT64, False))
        var ids = List[Int64]()
        ids.append(nid)
        rb.add_column(
            Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(ids))
        )
    sb.add_field(Field("name_embedding", ArrowType.STRING, True))
    rb.add_column(
        Column.from_string(StringArray.from_strings_with_validity(cells, valid))
    )
    return rb.build(sb.build())


def test_a_projection_batch_decodes_and_a_malformed_one_is_refused() raises:
    var rows = decode_embedding_projection(_projection(7, False, False), DIM)
    assert_equal(len(rows.nids), 1)
    assert_equal(rows.nids[0], 7)
    assert_equal(rows.vectors[0][0], 1.0)
    assert_equal(rows.vectors[0][1], 0.0)
    with assert_raises(contains="null embedding cell, row 0"):
        _ = decode_embedding_projection(_projection(7, True, False), DIM)
    with assert_raises(contains="node id -1 is out of range"):
        _ = decode_embedding_projection(_projection(-1, False, False), DIM)
    with assert_raises(contains="column 0 is not INT64"):
        _ = decode_embedding_projection(_projection(0, False, True), DIM)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
