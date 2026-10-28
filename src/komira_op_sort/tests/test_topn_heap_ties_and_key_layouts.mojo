# =============================================================================
# Top-N: tied rows, INT32 keys, sliced columns, numeric-dictionary keys
# =============================================================================
#
# Every batch here is in the bounded heap's regime (`num_rows > k *
# TOPN_HEAP_RATIO`), asserted by `test_every_batch_here_is_in_the_heap_regime`
# from the ratio the router reads.
#
#   * Tied rows: when the keys tie across the cut, the rows kept and the order
#     they come out in are the INPUT order, in both directions, and the heap
#     answers exactly as the stable full sort does.
#   * INT32 keys: the heap has an INT32 comparator arm.
#   * Sliced columns: a column that starts at a nonzero offset (an INT64 key,
#     a STRING key) is read from that offset.
#   * Numeric-dictionary keys: the schema reports the logical type (INT64)
#     while the column stores dictionary codes. The sink orders by the
#     VALUES the codes name, with 64-bit and 32-bit codes; the heap itself
#     refuses such a column.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_raises

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_physical_plan.physical_plan import TopNSinkData

from komira_op_sort.sort_topn_heap import topn_heap_select
from komira_op_sort.sort_topn_sink import (
    TOPN_HEAP_RATIO,
    _execute_topn_sink,
    _heap_can_order_all_keys,
    _string_key_is_heap_safe,
)


comptime _N_ROWS: Int = 100


def _keys1(a: String) -> List[String]:
    var k = List[String]()
    k.append(a)
    return k^


def _keys2(a: String, b: String) -> List[String]:
    var k = List[String]()
    k.append(a)
    k.append(b)
    return k^


def _desc1(a: Bool) -> List[Bool]:
    var d = List[Bool]()
    d.append(a)
    return d^


def _desc2(a: Bool, b: Bool) -> List[Bool]:
    var d = List[Bool]()
    d.append(a)
    d.append(b)
    return d^


def _spec(keys: List[String], desc: List[Bool], n: Int) raises -> TopNSinkData:
    var k = keys.copy()
    var d = desc.copy()
    return TopNSinkData(k^, d^, n)


def _i64_at(rb: RecordBatch, col: Int, row: Int) raises -> Int:
    return Int(rb.column_as_primitive_int64(col).load[1](row)[0])


def _assert_v_column(
    rb: RecordBatch, v_col: Int, expect: List[Int], label: String
) raises:
    assert_equal(rb.num_rows(), len(expect), label + ": row count")
    for r in range(len(expect)):
        assert_equal(
            _i64_at(rb, v_col, r), expect[r], label + ": v @" + String(r)
        )


# -----------------------------------------------------------------------------
# Tied rows
# -----------------------------------------------------------------------------


def _tied_batch() raises -> RecordBatch:
    """`[k INT64, z INT64, v INT64]`: k = row % 5 (twenty rows per value),
    z = 0 for every row, v = row + 1 (the row id)."""
    var k = PrimitiveArray[DType.int64].allocate(_N_ROWS)
    var z = PrimitiveArray[DType.int64].allocate(_N_ROWS)
    var v = PrimitiveArray[DType.int64].allocate(_N_ROWS)
    for i in range(_N_ROWS):
        k.set_typed[Scalar[DType.int64]](i, Int64(i % 5))
        z.set_typed[Scalar[DType.int64]](i, Int64(0))
        v.set_typed[Scalar[DType.int64]](i, Int64(i + 1))
    var builder = RecordBatchBuilder.with_capacity(3)
    builder.add_column(Column.from_primitive[DType.int64](k^))
    builder.add_column(Column.from_primitive[DType.int64](z^))
    builder.add_column(Column.from_primitive[DType.int64](v^))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("z", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    return builder.build(sb.build())


def test_every_batch_here_is_in_the_heap_regime() raises:
    # (k used below) 7 and 5 with 100 rows.
    assert_true(_N_ROWS > 7 * TOPN_HEAP_RATIO, "K=7 is not in the heap regime")
    assert_true(_N_ROWS > 5 * TOPN_HEAP_RATIO, "K=5 is not in the heap regime")
    # And the full-sort comparison size is not.
    assert_true(
        not (_N_ROWS > 20 * TOPN_HEAP_RATIO),
        "K=20 reached the heap, so it is not a full-sort reference",
    )
    var rb = _tied_batch()
    assert_true(
        _heap_can_order_all_keys(rb, _keys1(String("k"))),
        "the INT64 key is not heap-comparable",
    )


def test_heap_keeps_tied_rows_in_input_order_asc() raises:
    """The value 0 of k holds twenty rows (ids 1, 6, 11, ...). LIMIT 7 keeps the first
    seven of them, in input order."""
    var rb = _execute_topn_sink(
        _tied_batch(), _spec(_keys1(String("k")), _desc1(False), 7)
    )
    var expect = List[Int]()
    for i in range(7):
        expect.append(1 + 5 * i)
    _assert_v_column(rb, 2, expect, String("k ASC LIMIT 7"))


def test_heap_keeps_tied_rows_in_input_order_desc() raises:
    """The value 4 of k holds twenty rows (ids 5, 10, 15, ...). LIMIT 7 keeps the first
    seven of them, in input order, also when the direction is DESC."""
    var rb = _execute_topn_sink(
        _tied_batch(), _spec(_keys1(String("k")), _desc1(True), 7)
    )
    var expect = List[Int]()
    for i in range(7):
        expect.append(5 + 5 * i)
    _assert_v_column(rb, 2, expect, String("k DESC LIMIT 7"))


def test_heap_keeps_rows_tied_on_every_key_in_input_order() raises:
    """Two keys, the second constant: the whole key list ties."""
    var rb = _execute_topn_sink(
        _tied_batch(),
        _spec(_keys2(String("k"), String("z")), _desc2(False, True), 7),
    )
    var expect = List[Int]()
    for i in range(7):
        expect.append(1 + 5 * i)
    _assert_v_column(rb, 2, expect, String("(k ASC, z DESC) LIMIT 7"))


def test_heap_answers_as_the_full_sort_does_on_ties() raises:
    """LIMIT 7 on the heap and LIMIT 20 on the full sort (20 * 8 > 100) return
    the same first seven rows."""
    for d in range(2):
        var desc = d == 1
        var heap = _execute_topn_sink(
            _tied_batch(), _spec(_keys1(String("k")), _desc1(desc), 7)
        )
        var full = _execute_topn_sink(
            _tied_batch(), _spec(_keys1(String("k")), _desc1(desc), 20)
        )
        assert_equal(full.num_rows(), 20, "full sort row count")
        var expect = List[Int]()
        for r in range(7):
            expect.append(_i64_at(full, 2, r))
        _assert_v_column(
            heap, 2, expect, String("heap vs full sort, desc=") + String(desc)
        )


# -----------------------------------------------------------------------------
# INT32 key
# -----------------------------------------------------------------------------


def _i32_batch() raises -> RecordBatch:
    """`[k INT32, v INT64]`: k = (row * 37) % 101 - 50 (distinct, signed)."""
    var k = PrimitiveArray[DType.int32].allocate(_N_ROWS)
    var v = PrimitiveArray[DType.int64].allocate(_N_ROWS)
    for i in range(_N_ROWS):
        k.set_typed[Scalar[DType.int32]](i, Int32((i * 37) % 101 - 50))
        v.set_typed[Scalar[DType.int64]](i, Int64(i + 1))
    var builder = RecordBatchBuilder.with_capacity(2)
    builder.add_column(Column.from_primitive[DType.int32](k^))
    builder.add_column(Column.from_primitive[DType.int64](v^))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT32, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    return builder.build(sb.build())


def _row_with_i32_rank(rank: Int) -> Int:
    """The row whose key has the given ascending rank (0 = smallest)."""
    for i in range(_N_ROWS):
        if (i * 37) % 101 == rank:
            return i
    return -1


def test_int32_key_asc_selects_the_smallest_in_order() raises:
    var rb = _execute_topn_sink(
        _i32_batch(), _spec(_keys1(String("k")), _desc1(False), 5)
    )
    var expect = List[Int]()
    for rank in range(5):
        expect.append(_row_with_i32_rank(rank) + 1)
    _assert_v_column(rb, 1, expect, String("INT32 k ASC LIMIT 5"))


def test_int32_key_desc_selects_the_largest_in_order() raises:
    var rb = _execute_topn_sink(
        _i32_batch(), _spec(_keys1(String("k")), _desc1(True), 5)
    )
    # Ranks 100 down to 96 exist only if a row holds them; take the five
    # largest ranks that some row holds.
    var expect = List[Int]()
    var rank = 100
    while len(expect) < 5:
        var row = _row_with_i32_rank(rank)
        if row >= 0:
            expect.append(row + 1)
        rank -= 1
    _assert_v_column(rb, 1, expect, String("INT32 k DESC LIMIT 5"))


# -----------------------------------------------------------------------------
# Sliced columns (nonzero offset)
# -----------------------------------------------------------------------------

comptime _SLICE_START: Int = 10


def _sliced_batch() raises -> RecordBatch:
    """`[s STRING, g INT64, v INT64]` over rows `_SLICE_START ..` of a longer
    column set. s = "w" + 3 digits of (row * 37) % 96 (distinct), g = row % 8,
    v = row + 1. Each column starts at the nonzero offset."""
    var labels = List[String](capacity=_N_ROWS)
    var g = PrimitiveArray[DType.int64].allocate(_N_ROWS)
    var v = PrimitiveArray[DType.int64].allocate(_N_ROWS)
    for i in range(_N_ROWS):
        var rank = (i * 37) % 96
        var digits = String(rank)
        while digits.byte_length() < 3:
            digits = String("0") + digits
        labels.append(String("w") + digits)
        g.set_typed[Scalar[DType.int64]](i, Int64(i % 8))
        v.set_typed[Scalar[DType.int64]](i, Int64(i + 1))
    var n = _N_ROWS - _SLICE_START

    var s_full = Column.from_string(StringArray.from_strings(labels))
    var s_col = s_full.share()
    s_col._offset = _SLICE_START
    s_col._length = n
    var g_col = Column.from_primitive[DType.int64](g^).slice(_SLICE_START, n)
    var v_col = Column.from_primitive[DType.int64](v^).slice(_SLICE_START, n)

    var builder = RecordBatchBuilder.with_capacity(3)
    builder.add_column(s_col^)
    builder.add_column(g_col^)
    builder.add_column(v_col^)
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, False))
    sb.add_field(Field("g", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    return builder.build(sb.build())


def test_sliced_batch_is_in_the_heap_regime() raises:
    var rb = _sliced_batch()
    assert_equal(rb.num_rows(), _N_ROWS - _SLICE_START, "sliced row count")
    assert_true(
        rb.num_rows() > 5 * TOPN_HEAP_RATIO, "the sliced batch is too short"
    )
    assert_true(
        rb.column_at(0)._offset == _SLICE_START
        and rb.column_at(1)._offset == _SLICE_START,
        "the fixture columns do not start at the slice offset",
    )
    assert_true(
        _heap_can_order_all_keys(rb, _keys2(String("s"), String("g"))),
        "a sliced STRING and INT64 key were refused by the router",
    )


def test_int64_key_is_read_from_the_column_offset() raises:
    """ORDER BY g, v LIMIT 5 over rows 10..99: g = 0 holds rows 16, 24, 32,
    40, 48 first."""
    var rb = _execute_topn_sink(
        _sliced_batch(),
        _spec(_keys2(String("g"), String("v")), _desc2(False, False), 5),
    )
    var expect = List[Int]()
    expect.append(17)
    expect.append(25)
    expect.append(33)
    expect.append(41)
    expect.append(49)
    _assert_v_column(rb, 2, expect, String("sliced g ASC, v ASC LIMIT 5"))


def _smallest_label_rows(k: Int, desc: Bool) -> List[Int]:
    """The v ids of the first `k` rows from `_SLICE_START` on, ordered by the
    label rank (row * 37) % 96."""
    var picked = List[Int]()
    var used = List[Bool]()
    for _ in range(_N_ROWS):
        used.append(False)
    for _ in range(k):
        var best = -1
        var best_rank = 0
        for i in range(_SLICE_START, _N_ROWS):
            if used[i]:
                continue
            var rank = (i * 37) % 96
            if best < 0 or (rank > best_rank if desc else rank < best_rank):
                best = i
                best_rank = rank
        used[best] = True
        picked.append(best + 1)
    return picked^


def test_string_key_is_read_from_the_column_offset_asc() raises:
    var rb = _execute_topn_sink(
        _sliced_batch(), _spec(_keys1(String("s")), _desc1(False), 5)
    )
    _assert_v_column(
        rb, 2, _smallest_label_rows(5, False), String("sliced s ASC LIMIT 5")
    )


def test_string_key_is_read_from_the_column_offset_desc() raises:
    var rb = _execute_topn_sink(
        _sliced_batch(), _spec(_keys1(String("s")), _desc1(True), 5)
    )
    _assert_v_column(
        rb, 2, _smallest_label_rows(5, True), String("sliced s DESC LIMIT 5")
    )


# -----------------------------------------------------------------------------
# Dictionary-encoded keys
# -----------------------------------------------------------------------------


def _numeric_dict_key_value(code: Int) -> Int:
    """The value dictionary entry `code` names: distinct, signed, and not in
    code order."""
    return ((code * 13) % 100) * 5 - 250


def _numeric_dict_batch[code_dt: DType]() raises -> RecordBatch:
    """`[k INT64 (dictionary), v INT64]`: row i holds code (i * 7) % 100, so
    its value is `_numeric_dict_key_value(code)`."""
    var codes = PrimitiveArray[code_dt].allocate(_N_ROWS)
    var v = PrimitiveArray[DType.int64].allocate(_N_ROWS)
    for i in range(_N_ROWS):
        codes.set_typed[Scalar[code_dt]](i, Scalar[code_dt]((i * 7) % 100))
        v.set_typed[Scalar[DType.int64]](i, Int64(i + 1))
    var values = List[Int64]()
    for c in range(100):
        values.append(Int64(_numeric_dict_key_value(c)))
    var k_col = Column.from_numeric_dict[code_dt, DType.int64](codes^, values^)

    var builder = RecordBatchBuilder.with_capacity(2)
    builder.add_column(k_col^)
    builder.add_column(Column.from_primitive[DType.int64](v^))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    return builder.build(sb.build())


def _row_with_value_rank(rank: Int) -> Int:
    """The row whose key value has the given ascending rank (0 = smallest)."""
    for i in range(_N_ROWS):
        if ((((i * 7) % 100) * 13) % 100) == rank:
            return i
    return -1


def test_numeric_dictionary_batch_reports_the_logical_type() raises:
    var rb = _numeric_dict_batch[DType.int64]()
    assert_true(rb.column_at(0).is_numeric_dict(), "k is not a dictionary")
    assert_true(
        rb.schema.field_arrow_type(0) == ArrowType.INT64,
        "the schema does not report the logical type",
    )


def test_router_refuses_a_numeric_dictionary_key() raises:
    var rb = _numeric_dict_batch[DType.int64]()
    assert_true(
        not _heap_can_order_all_keys(rb, _keys1(String("k"))),
        "the router admitted a dictionary-encoded INT64 key to the heap",
    )


def test_heap_refuses_a_numeric_dictionary_key() raises:
    var rb = _numeric_dict_batch[DType.int64]()
    with assert_raises(contains="_topn_heap"):
        _ = topn_heap_select(rb, _spec(_keys1(String("k")), _desc1(False), 4))


def test_top_n_orders_by_the_values_of_int64_codes_asc() raises:
    var rb = _execute_topn_sink(
        _numeric_dict_batch[DType.int64](),
        _spec(_keys1(String("k")), _desc1(False), 4),
    )
    var expect = List[Int]()
    for rank in range(4):
        expect.append(_row_with_value_rank(rank) + 1)
    _assert_v_column(rb, 1, expect, String("dictionary k ASC LIMIT 4"))


def test_top_n_orders_by_the_values_of_int64_codes_desc() raises:
    var rb = _execute_topn_sink(
        _numeric_dict_batch[DType.int64](),
        _spec(_keys1(String("k")), _desc1(True), 4),
    )
    var expect = List[Int]()
    for rank in range(99, 95, -1):
        expect.append(_row_with_value_rank(rank) + 1)
    _assert_v_column(rb, 1, expect, String("dictionary k DESC LIMIT 4"))


def test_top_n_orders_by_the_values_of_int32_codes() raises:
    """32-bit codes under a 64-bit key: the answer is the same."""
    var rb = _execute_topn_sink(
        _numeric_dict_batch[DType.int32](),
        _spec(_keys1(String("k")), _desc1(False), 4),
    )
    var expect = List[Int]()
    for rank in range(4):
        expect.append(_row_with_value_rank(rank) + 1)
    _assert_v_column(rb, 1, expect, String("int32-code k ASC LIMIT 4"))


def test_top_n_with_a_numeric_dictionary_key_among_several() raises:
    var rb = _execute_topn_sink(
        _numeric_dict_batch[DType.int64](),
        _spec(_keys2(String("k"), String("v")), _desc2(False, False), 4),
    )
    var expect = List[Int]()
    for rank in range(4):
        expect.append(_row_with_value_rank(rank) + 1)
    _assert_v_column(rb, 1, expect, String("(dictionary k, v) LIMIT 4"))


def _string_dict_batch() raises -> RecordBatch:
    """`[s (dictionary of STRING), v INT64]`: 100 rows over 5 entries."""
    var words = List[String]()
    words.append(String("delta"))
    words.append(String("alpha"))
    words.append(String("echo"))
    words.append(String("charlie"))
    words.append(String("bravo"))
    var indices = PrimitiveArray[DType.int32].allocate(_N_ROWS)
    var v = PrimitiveArray[DType.int64].allocate(_N_ROWS)
    for i in range(_N_ROWS):
        indices.set_typed[Scalar[DType.int32]](i, Int32(i % 5))
        v.set_typed[Scalar[DType.int64]](i, Int64(i + 1))
    var dict_arr = StringDictionaryArray.from_parts(
        indices^, StringArray.from_strings(words)
    )
    var builder = RecordBatchBuilder.with_capacity(2)
    builder.add_column(Column.from_dictionary(dict_arr))
    builder.add_column(Column.from_primitive[DType.int64](v^))
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    return builder.build(sb.build())


def test_string_dictionary_key_is_not_heap_safe() raises:
    """A DICTIONARY column holds (indices, dictionary), not (offsets, data):
    the STRING arm of the heap cannot read it."""
    var rb = _string_dict_batch()
    assert_true(
        rb.column_at(0).arrow_type == ArrowType.DICTIONARY,
        "the fixture column is not a dictionary",
    )
    assert_true(
        not _string_key_is_heap_safe(rb, 0),
        "a dictionary-encoded STRING key was judged heap-safe",
    )
    assert_true(
        not _heap_can_order_all_keys(rb, _keys1(String("s"))),
        "the router admitted a dictionary-encoded STRING key to the heap",
    )


# -----------------------------------------------------------------------------
# Sliced FLOAT64 and INT32 keys
# -----------------------------------------------------------------------------


def _sliced_key_rank(u: Int) -> Int:
    """The key value of underlying row `u`. The rows before `_SLICE_START` sit
    far outside the range of the rest, alternating low and high, so a key read
    from the start of the buffer instead of the column offset puts them in
    the cut in both directions."""
    if u < _SLICE_START:
        return -1000 - u if u % 2 == 0 else 1000 + u
    return (u * 37) % 101


def _sliced_float_int_batch() raises -> RecordBatch:
    """`[f FLOAT64, q INT32, v INT64]` over rows `_SLICE_START ..` of a
    buffer of `_N_ROWS` rows. f and q hold `_sliced_key_rank` (f as rank +
    0.5), v = row + 1. Each column starts at the nonzero offset."""
    var f = PrimitiveArray[DType.float64].allocate(_N_ROWS)
    var q = PrimitiveArray[DType.int32].allocate(_N_ROWS)
    var v = PrimitiveArray[DType.int64].allocate(_N_ROWS)
    for i in range(_N_ROWS):
        var rank = _sliced_key_rank(i)
        f.set_typed[Scalar[DType.float64]](i, Float64(rank) + 0.5)
        q.set_typed[Scalar[DType.int32]](i, Int32(rank))
        v.set_typed[Scalar[DType.int64]](i, Int64(i + 1))
    var n = _N_ROWS - _SLICE_START
    var builder = RecordBatchBuilder.with_capacity(3)
    builder.add_column(
        Column.from_primitive[DType.float64](f^).slice(_SLICE_START, n)
    )
    builder.add_column(
        Column.from_primitive[DType.int32](q^).slice(_SLICE_START, n)
    )
    builder.add_column(
        Column.from_primitive[DType.int64](v^).slice(_SLICE_START, n)
    )
    var sb = SchemaBuilder()
    sb.add_field(Field("f", ArrowType.FLOAT64, False))
    sb.add_field(Field("q", ArrowType.INT32, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    return builder.build(sb.build())


def _sliced_key_rows(k: Int, desc: Bool) -> List[Int]:
    """The v ids of the first `k` rows from `_SLICE_START` on, ordered by
    `_sliced_key_rank` (the ranks of those rows are distinct)."""
    var picked = List[Int]()
    var used = List[Bool]()
    for _ in range(_N_ROWS):
        used.append(False)
    for _ in range(k):
        var best = -1
        var best_rank = 0
        for i in range(_SLICE_START, _N_ROWS):
            if used[i]:
                continue
            var rank = _sliced_key_rank(i)
            if best < 0 or (rank > best_rank if desc else rank < best_rank):
                best = i
                best_rank = rank
        used[best] = True
        picked.append(best + 1)
    return picked^


def test_sliced_float_and_int32_batch_is_in_the_heap_regime() raises:
    var rb = _sliced_float_int_batch()
    assert_true(
        rb.num_rows() > 5 * TOPN_HEAP_RATIO, "the sliced batch is too short"
    )
    assert_true(
        rb.column_at(0)._offset == _SLICE_START
        and rb.column_at(1)._offset == _SLICE_START,
        "the fixture columns do not start at the slice offset",
    )
    assert_true(
        _heap_can_order_all_keys(rb, _keys2(String("f"), String("q"))),
        "a sliced FLOAT64 and INT32 key were refused by the router",
    )


def test_float64_key_is_read_from_the_column_offset_asc() raises:
    var rb = _execute_topn_sink(
        _sliced_float_int_batch(), _spec(_keys1(String("f")), _desc1(False), 5)
    )
    _assert_v_column(
        rb, 2, _sliced_key_rows(5, False), String("sliced f ASC LIMIT 5")
    )


def test_float64_key_is_read_from_the_column_offset_desc() raises:
    var rb = _execute_topn_sink(
        _sliced_float_int_batch(), _spec(_keys1(String("f")), _desc1(True), 5)
    )
    _assert_v_column(
        rb, 2, _sliced_key_rows(5, True), String("sliced f DESC LIMIT 5")
    )


def test_int32_key_is_read_from_the_column_offset_asc() raises:
    var rb = _execute_topn_sink(
        _sliced_float_int_batch(), _spec(_keys1(String("q")), _desc1(False), 5)
    )
    _assert_v_column(
        rb, 2, _sliced_key_rows(5, False), String("sliced q ASC LIMIT 5")
    )


def test_int32_key_is_read_from_the_column_offset_desc() raises:
    var rb = _execute_topn_sink(
        _sliced_float_int_batch(), _spec(_keys1(String("q")), _desc1(True), 5)
    )
    _assert_v_column(
        rb, 2, _sliced_key_rows(5, True), String("sliced q DESC LIMIT 5")
    )


# -----------------------------------------------------------------------------
# Mixed directions with partial ties
# -----------------------------------------------------------------------------


def _mixed_batch() raises -> RecordBatch:
    """`[a INT64, b INT64, v INT64]`: a = row % 5 (twenty rows per value),
    b = (row * 7) % 13 (equal for rows 13 apart, so some rows tie on both
    keys too), v = row + 1."""
    var a = PrimitiveArray[DType.int64].allocate(_N_ROWS)
    var b = PrimitiveArray[DType.int64].allocate(_N_ROWS)
    var v = PrimitiveArray[DType.int64].allocate(_N_ROWS)
    for i in range(_N_ROWS):
        a.set_typed[Scalar[DType.int64]](i, Int64(i % 5))
        b.set_typed[Scalar[DType.int64]](i, Int64((i * 7) % 13))
        v.set_typed[Scalar[DType.int64]](i, Int64(i + 1))
    var builder = RecordBatchBuilder.with_capacity(3)
    builder.add_column(Column.from_primitive[DType.int64](a^))
    builder.add_column(Column.from_primitive[DType.int64](b^))
    builder.add_column(Column.from_primitive[DType.int64](v^))
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    return builder.build(sb.build())


def _heap_equals_full_sort_on_mixed_directions(
    desc_a: Bool, desc_b: Bool
) raises:
    """LIMIT 7 on the heap cuts inside the twenty rows that tie on `a`, which
    differ on `b` in the opposite direction; LIMIT 20 (20 * 8 > 100) takes the
    full sort. The first seven rows must agree."""
    var heap = _execute_topn_sink(
        _mixed_batch(),
        _spec(_keys2(String("a"), String("b")), _desc2(desc_a, desc_b), 7),
    )
    var full = _execute_topn_sink(
        _mixed_batch(),
        _spec(_keys2(String("a"), String("b")), _desc2(desc_a, desc_b), 20),
    )
    assert_equal(full.num_rows(), 20, "full sort row count")
    var expect = List[Int]()
    for r in range(7):
        expect.append(_i64_at(full, 2, r))
    _assert_v_column(
        heap,
        2,
        expect,
        String("heap vs full sort, desc=")
        + String(desc_a)
        + String(",")
        + String(desc_b),
    )
    # The cut sits inside one `a` value, so the test reaches the partial tie.
    var a0 = _i64_at(heap, 0, 0)
    for r in range(7):
        assert_equal(_i64_at(heap, 0, r), a0, "the cut left the tied a value")


def test_heap_matches_full_sort_on_asc_desc_with_partial_ties() raises:
    _heap_equals_full_sort_on_mixed_directions(False, True)


def test_heap_matches_full_sort_on_desc_asc_with_partial_ties() raises:
    _heap_equals_full_sort_on_mixed_directions(True, False)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
