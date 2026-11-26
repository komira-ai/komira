# =============================================================================
# The COUNT(DISTINCT) state by itself: value cells, entries, merge, limits
# =============================================================================
#
# `count_distinct` keeps a worker's (aggregate, group, value) entries and
# merges them into counts. These tests drive `read_distinct_column`,
# `admit_distinct` and `DistinctMerge` directly, so the limits the sinks reach
# only past a billion entries are reached with a table of 64 or fewer. The
# expected values are written from the inputs here. What they prove:
#
#   * test_the_served_argument_types_are_the_documented_ones: INT8 to INT64,
#     DATE32, FLOAT32, FLOAT64, DECIMAL128, STRING and DICTIONARY are served,
#     every other type is not.
#   * test_the_two_refusals_are_worded_as_documented: the text of a denied pool
#     and of a full table, by exact equality.
#   * test_an_integer_column_reads_as_its_values_with_a_flag_for_null: the value
#     cells of INT64 are the values, a NULL row is flagged and has cells 0.
#   * test_floats_read_as_equal_cells_exactly_when_duckdb_calls_them_equal:
#     every NaN reads as one cell, -0.0 and 0.0 as one, and a value, its
#     neighbour and the infinities read as different cells.
#   * test_a_decimal_reads_as_its_low_and_its_high_word: two cells, low then
#     high, and a NULL row of 0 and 0.
#   * test_strings_read_by_value_whatever_the_form_of_the_column: one id for one
#     string in a flat column and in dictionaries numbered differently, a NULL
#     row flagged, the empty string a value.
#   * test_a_column_the_reader_cannot_serve_is_refused_by_exact_message: a
#     column of another row count, an unserved type, a numeric dictionary and
#     a type that changed.
#   * test_a_string_table_that_is_full_or_denied_is_refused_by_name: more
#     distinct strings than the table holds (and exactly as many, and a string
#     seen again, are not refused) and a pool that denies the first entries.
#   * test_a_null_row_admits_nothing_and_an_entry_is_made_once: entries are
#     per aggregate, per group and per value.
#   * test_a_table_of_entries_holds_its_limit_and_refuses_one_more: 64 entries
#     fit, a 65th is refused by exact message, a 64th seen again is not.
#   * test_a_pool_that_denies_the_entries_is_refused_by_exact_message: the first
#     entries of an INT64 value.
#   * test_a_merge_counts_each_value_once_in_each_merged_group: two aggregates
#     (an integer and a string numbered differently on the two workers), two
#     workers, workers' groups mapped to merged groups, a value met by both
#     workers counted once.
#   * test_a_merge_refuses_an_aggregate_that_changed_type_between_workers: by
#     exact message, and a worker that read no morsel for an aggregate is no
#     other type.
#   * test_a_merge_table_that_is_full_is_refused_by_name: 64 values merge, 65
#     are refused by exact message, and 1 distinct string fits a string table of
#     1 while 2 are refused.
#   * test_a_merge_the_pool_denies_is_refused_by_exact_message: the merged
#     entries of an integer and the merged strings.
#   * test_finish_returns_the_merge_memory_and_empties_its_tables: the pool is
#     charged by the merge and whole after `finish`.

from std.memory import bitcast
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_true,
)

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.column_builder import ColumnBuilder
from arrow.decimal_array import Decimal128Array
from arrow.primitive_array import PrimitiveArray
from arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from pipeline_exec.agg_fold import AggCell
from pipeline_exec.count_distinct import (
    DistinctColumn,
    DistinctMerge,
    DistinctSlot,
    admit_distinct,
    distinct_denied,
    distinct_too_many,
    is_distinct_value_type,
    read_distinct_column,
)
from pipeline_exec.group_table import GroupTable
from pipeline_exec.segment_pool import SegmentPool, WorkerReservation
from pipeline_exec.string_harness import (
    FORM_DICT,
    FORM_FLAT,
    FORM_SHUFFLED,
    string_column,
)
from scalar_arithmetic.decimal_arith import I128

comptime NUL: Int = -999999
"""In a list of test values: this row is NULL."""

comptime NULL_STR = "<NULL>"
"""In a list of test strings: this row is NULL."""

comptime NULL_BITS: UInt64 = 0x1234567812345678
"""In a list of float bit patterns: this row is NULL."""

comptime WHERE = "w"
comptime LABEL = "COUNT(DISTINCT) (output column 0)"


def _entries_bytes() -> Int:
    """The bytes the first step of the entry table asks for: 64 entries."""
    return 64 * GroupTable(4, 0).per_group_bytes()


# --- batches of one column `x` ----------------------------------------------


def _int_batch(vals: List[Int]) raises -> RecordBatch:
    var b = ColumnBuilder[DType.int64].with_capacity(len(vals))
    for i in range(len(vals)):
        if vals[i] == NUL:
            b.append_null()
        else:
            b.append(Int64(vals[i]))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("x", ArrowType.INT64, True))
    rb.add_column(b^.materialize())
    return rb.build(sb.build())


def _range_batch(n: Int) raises -> RecordBatch:
    """INT64 values 0 to n - 1."""
    var vals = List[Int]()
    for i in range(n):
        vals.append(i)
    return _int_batch(vals)


def _f64_batch(bits: List[UInt64]) raises -> RecordBatch:
    var b = ColumnBuilder[DType.float64].with_capacity(len(bits))
    for i in range(len(bits)):
        if bits[i] == NULL_BITS:
            b.append_null()
        else:
            b.append(bitcast[DType.float64](bits[i]))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("x", ArrowType.FLOAT64, True))
    rb.add_column(b^.materialize())
    return rb.build(sb.build())


def _dec_batch(vals: List[I128], valid: List[Bool]) raises -> RecordBatch:
    var arr = Decimal128Array.allocate_nullable(len(vals), 38, 0)
    for i in range(len(vals)):
        if valid[i]:
            arr.set_i128(i, vals[i])
        else:
            arr.set_null(i)
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field.decimal128("x", 38, 0, True))
    rb.add_column(Column.from_decimal128(arr^))
    return rb.build(sb.build())


def _str_batch(
    vals: List[String], form: Int = FORM_FLAT, rot: Int = 0
) raises -> RecordBatch:
    var values = List[String]()
    var valid = List[Bool]()
    for i in range(len(vals)):
        valid.append(vals[i] != NULL_STR)
        if vals[i] == NULL_STR:
            values.append(String(""))
        else:
            values.append(vals[i].copy())
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    if form == FORM_FLAT:
        sb.add_field(Field("x", ArrowType.STRING, True))
    else:
        sb.add_field(Field.dictionary("x", ArrowType.INT32, True))
    rb.add_column(string_column(values, valid, form, rot))
    return rb.build(sb.build())


def _numeric_dict_batch() raises -> RecordBatch:
    """A DICTIONARY column whose values are INT64, not strings."""
    var codes = PrimitiveArray[DType.int32].allocate(2)
    codes.set(0, 0)
    codes.set(1, 1)
    var nums = List[Int64]()
    nums.append(10)
    nums.append(20)
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field.dictionary("x", ArrowType.INT32, False))
    rb.add_column(
        Column.from_numeric_dict[DType.int32, DType.int64](codes^, nums^)
    )
    return rb.build(sb.build())


def _u32_batch() raises -> RecordBatch:
    var arr = PrimitiveArray[DType.uint32].allocate(3)
    for i in range(3):
        arr.set(i, UInt32(i))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("x", ArrowType.UINT32, False))
    rb.add_column(Column.from_primitive[DType.uint32](arr^))
    return rb.build(sb.build())


# --- reading and admitting ---------------------------------------------------


def _read(
    mut slot: DistinctSlot,
    agg: Int,
    ref batch: RecordBatch,
    ref pool: SegmentPool,
    mut res: WorkerReservation,
) raises -> DistinctColumn:
    var where_ = String(WHERE)
    var label = String(LABEL)
    return read_distinct_column(
        slot, agg, batch, 0, batch.num_rows(), where_, label, pool, res
    )


def _read_error(
    mut slot: DistinctSlot,
    agg: Int,
    ref batch: RecordBatch,
    rows: Int,
    ref pool: SegmentPool,
    mut res: WorkerReservation,
) raises -> String:
    """The error reading column 0 of `batch` as `rows` rows raises, or the
    empty string."""
    var where_ = String(WHERE)
    var label = String(LABEL)
    try:
        _ = read_distinct_column(
            slot, agg, batch, 0, rows, where_, label, pool, res
        )
    except e:
        return String(e)
    return String("")


def _admit(
    mut slot: DistinctSlot,
    agg: Int,
    group: Int,
    ref col: DistinctColumn,
    row: Int,
    ref pool: SegmentPool,
    mut res: WorkerReservation,
) raises:
    var where_ = String(WHERE)
    admit_distinct(slot, agg, group, col, row, where_, pool, res)


def _admit_error(
    mut slot: DistinctSlot,
    agg: Int,
    group: Int,
    ref col: DistinctColumn,
    row: Int,
    ref pool: SegmentPool,
    mut res: WorkerReservation,
) raises -> String:
    try:
        _admit(slot, agg, group, col, row, pool, res)
    except e:
        return String(e)
    return String("")


def _fill(
    mut slot: DistinctSlot,
    agg: Int,
    ref batch: RecordBatch,
    groups: List[Int],
    ref pool: SegmentPool,
    mut res: WorkerReservation,
) raises:
    """Admit row r of column 0 of `batch` under worker group `groups[r]`."""
    var col = _read(slot, agg, batch, pool, res)
    for r in range(len(groups)):
        _admit(slot, agg, groups[r], col, r, pool, res)


def _int_slot(
    vals: List[Int],
    groups: List[Int],
    ref pool: SegmentPool,
    mut res: WorkerReservation,
    num_aggs: Int = 1,
) raises -> DistinctSlot:
    var slot = DistinctSlot(num_aggs)
    _fill(slot, 0, _int_batch(vals), groups, pool, res)
    return slot^


def _new_cells(n: Int) -> List[AggCell]:
    var cells = List[AggCell]()
    for _ in range(n):
        cells.append(AggCell())
    return cells^


def _labels(n: Int) -> List[String]:
    var out = List[String]()
    for _ in range(n):
        out.append(String(LABEL))
    return out^


def _merge_error(
    mut merge: DistinctMerge,
    ref slot: DistinctSlot,
    group_map: List[Int],
    mut cells: List[AggCell],
    num_aggs: Int,
    ref pool: SegmentPool,
) raises -> String:
    var where_ = String(WHERE)
    var labels = _labels(num_aggs)
    try:
        merge.merge_worker(
            slot, group_map, cells, num_aggs, where_, labels, pool
        )
    except e:
        return String(e)
    return String("")


def _merge(
    mut merge: DistinctMerge,
    ref slot: DistinctSlot,
    group_map: List[Int],
    mut cells: List[AggCell],
    num_aggs: Int,
    ref pool: SegmentPool,
) raises:
    var where_ = String(WHERE)
    var labels = _labels(num_aggs)
    merge.merge_worker(slot, group_map, cells, num_aggs, where_, labels, pool)


def _repeat(v: Int, n: Int) -> List[Int]:
    var out = List[Int]()
    for _ in range(n):
        out.append(v)
    return out^


def _range_list(n: Int) -> List[Int]:
    var out = List[Int]()
    for i in range(n):
        out.append(i)
    return out^


def _too_many(max_entries: Int) -> String:
    return (
        String(WHERE)
        + " has more COUNT(DISTINCT) values than it holds ("
        + String(max_entries)
        + " distinct values, distinct strings, or a string over 2 GiB)"
    )


def _denied(bytes: Int, budget: Int, granted: Int) -> String:
    return (
        String("MEMORY_BUDGET_EXCEEDED: ")
        + String(WHERE)
        + " was denied "
        + String(bytes)
        + " bytes of the segment's memory pool for its COUNT(DISTINCT)"
        " values (budget "
        + String(budget)
        + ", granted "
        + String(granted)
        + ")"
    )


# --- tests -------------------------------------------------------------------


def test_the_served_argument_types_are_the_documented_ones() raises:
    var served = List[ArrowType]()
    served.append(ArrowType.INT8)
    served.append(ArrowType.INT16)
    served.append(ArrowType.INT32)
    served.append(ArrowType.INT64)
    served.append(ArrowType.DATE32)
    served.append(ArrowType.FLOAT32)
    served.append(ArrowType.FLOAT64)
    served.append(ArrowType.DECIMAL128)
    served.append(ArrowType.STRING)
    served.append(ArrowType.DICTIONARY)
    for i in range(len(served)):
        assert_true(is_distinct_value_type(served[i]), String(served[i]))
    var refused = List[ArrowType]()
    refused.append(ArrowType.NULL)
    refused.append(ArrowType.BOOL)
    refused.append(ArrowType.UINT8)
    refused.append(ArrowType.UINT16)
    refused.append(ArrowType.UINT32)
    refused.append(ArrowType.UINT64)
    refused.append(ArrowType.FLOAT16)
    refused.append(ArrowType.BINARY)
    refused.append(ArrowType.LARGE_STRING)
    for i in range(len(refused)):
        assert_false(is_distinct_value_type(refused[i]), String(refused[i]))


def test_the_two_refusals_are_worded_as_documented() raises:
    var pool = SegmentPool(7)
    var where_ = String(WHERE)
    assert_equal(
        String(distinct_denied(where_, 5, pool)), _denied(5, 7, 0)
    )
    assert_equal(String(distinct_too_many(where_, 3)), _too_many(3))


def test_an_integer_column_reads_as_its_values_with_a_flag_for_null() raises:
    var pool = SegmentPool()
    var res = WorkerReservation(pool.share())
    var slot = DistinctSlot(1)
    var col = _read(slot, 0, _int_batch(List[Int]([5, NUL, -3])), pool, res)
    assert_equal(len(col.null), 3)
    assert_equal(len(col.cells), 6)
    assert_equal(Int(col.null[0]), 0)
    assert_equal(Int(col.null[1]), 1)
    assert_equal(Int(col.null[2]), 0)
    assert_equal(Int(col.cells[0]), 5)
    assert_equal(Int(col.cells[2]), 0)
    assert_equal(Int(col.cells[4]), -3)
    # Every second cell, and every cell of a NULL row, is 0.
    assert_equal(Int(col.cells[1]), 0)
    assert_equal(Int(col.cells[3]), 0)
    assert_equal(Int(col.cells[5]), 0)


def test_floats_read_as_equal_cells_exactly_when_duckdb_calls_them_equal() raises:
    var pool = SegmentPool()
    var res = WorkerReservation(pool.share())
    var slot = DistinctSlot(1)
    var bits = List[UInt64](
        [UInt64(0x7FF8000000000000),  # 0: a quiet NaN
        UInt64(0xFFF8000000000000),  # 1: a negative NaN
        UInt64(0x7FF0000000000001),  # 2: a signalling NaN
        UInt64(0x7FF8000000000123),  # 3: a NaN with a payload
        UInt64(0x8000000000000000),  # 4: -0.0
        UInt64(0x0000000000000000),  # 5: 0.0
        UInt64(0x3FF8000000000000),  # 6: 1.5
        UInt64(0x3FF8000000000001),  # 7: the double above 1.5
        UInt64(0x7FF0000000000000),  # 8: +inf
        UInt64(0xFFF0000000000000),  # 9: -inf
        NULL_BITS,  # 10: NULL
        ]
    )
    var col = _read(slot, 0, _f64_batch(bits), pool, res)
    for i in range(1, 4):
        assert_equal(col.cells[2 * i], col.cells[0], "NaN " + String(i))
    assert_equal(col.cells[8], col.cells[10], "-0.0 and 0.0")
    # Every other pair of the values is a pair of different cells.
    var classes = List[Int]([0, 8, 12, 14, 16, 18])
    for i in range(len(classes)):
        for j in range(len(classes)):
            if i != j:
                assert_true(
                    col.cells[classes[i]] != col.cells[classes[j]],
                    String(classes[i]) + " and " + String(classes[j]),
                )
    assert_equal(Int(col.null[10]), 1)
    assert_equal(Int(col.null[0]), 0)
    assert_equal(Int(col.cells[20]), 0)


def test_a_decimal_reads_as_its_low_and_its_high_word() raises:
    var pool = SegmentPool()
    var res = WorkerReservation(pool.share())
    var slot = DistinctSlot(1)
    var big = I128(4294967296) * I128(4294967296)
    var vals = List[I128]([big + I128(3), I128(0) - I128(1), I128(7), I128(0)])
    var valid = List[Bool]([True, True, True, False])
    var col = _read(slot, 0, _dec_batch(vals, valid), pool, res)
    assert_equal(len(col.cells), 8)
    # 2^64 + 3: low word 3, high word 1.
    assert_equal(Int(col.cells[0]), 3)
    assert_equal(Int(col.cells[1]), 1)
    # -1: both words all ones.
    assert_equal(Int(col.cells[2]), -1)
    assert_equal(Int(col.cells[3]), -1)
    assert_equal(Int(col.cells[4]), 7)
    assert_equal(Int(col.cells[5]), 0)
    assert_equal(Int(col.null[3]), 1)
    assert_equal(Int(col.cells[6]), 0)
    assert_equal(Int(col.cells[7]), 0)
    assert_equal(Int(col.null[0]) + Int(col.null[1]) + Int(col.null[2]), 0)


def test_strings_read_by_value_whatever_the_form_of_the_column() raises:
    var pool = SegmentPool()
    var res = WorkerReservation(pool.share())
    var slot = DistinctSlot(1)
    var flat = _read(
        slot,
        0,
        _str_batch(List[String](["pear", "apple", "", NULL_STR, "pear"])),
        pool,
        res,
    )
    assert_equal(Int(flat.cells[0]), 0)
    assert_equal(Int(flat.cells[2]), 1)
    assert_equal(Int(flat.cells[4]), 2)
    assert_equal(Int(flat.null[3]), 1)
    assert_equal(Int(flat.null[2]), 0)
    assert_equal(Int(flat.cells[8]), Int(flat.cells[0]))
    # Dictionaries that code the strings differently read as the same ids.
    var forms = List[Int]([FORM_DICT, FORM_SHUFFLED])
    for f in range(len(forms)):
        var form = forms[f]
        var dict = _read(
            slot,
            0,
            _str_batch(
                List[String](["apple", NULL_STR, "", "pear"]), form, 1
            ),
            pool,
            res,
        )
        assert_equal(Int(dict.cells[0]), Int(flat.cells[2]))
        assert_equal(Int(dict.null[1]), 1)
        assert_equal(Int(dict.cells[4]), Int(flat.cells[4]))
        assert_equal(Int(dict.cells[6]), Int(flat.cells[0]))
    # A string that is new takes the next id.
    var more = _read(slot, 0, _str_batch(List[String](["fig"])), pool, res)
    assert_equal(Int(more.cells[0]), 3)
    assert_equal(slot.values.n, 4)


def test_a_column_the_reader_cannot_serve_is_refused_by_exact_message() raises:
    var pool = SegmentPool()
    var res = WorkerReservation(pool.share())
    var slot = DistinctSlot(1)
    assert_equal(
        _read_error(slot, 0, _range_batch(3), 2, pool, res),
        "pipeline_exec: "
        + String(LABEL)
        + " got a column of 3 rows for 2 selected rows",
    )
    assert_equal(
        _read_error(slot, 0, _u32_batch(), 3, pool, res),
        "pipeline_exec: "
        + String(LABEL)
        + " is not served over this column type (uint32): COUNT(DISTINCT)"
        " takes INT8 to INT64, DATE32, FLOAT32, FLOAT64, DECIMAL128 and"
        " strings",
    )
    assert_equal(
        _read_error(slot, 0, _numeric_dict_batch(), 2, pool, res),
        "pipeline_exec: "
        + String(LABEL)
        + " is not served over this column type ("
        + String(ArrowType.DICTIONARY)
        + "): COUNT(DISTINCT) takes INT8 to INT64, DATE32, FLOAT32,"
        " FLOAT64, DECIMAL128 and strings",
    )
    # The first read of an aggregate gives it its type, a second type is
    # refused, and a dictionary is the same type as a flat string.
    assert_equal(_read_error(slot, 0, _range_batch(3), 3, pool, res), "")
    assert_equal(
        _read_error(
            slot, 0, _str_batch(List[String](["a"])), 1, pool, res
        ),
        "pipeline_exec: "
        + String(LABEL)
        + " saw a column of another type than the morsels before it",
    )
    var strs = DistinctSlot(1)
    assert_equal(
        _read_error(
            strs, 0, _str_batch(List[String](["a"])), 1, pool, res
        ),
        "",
    )
    assert_equal(
        _read_error(
            strs,
            0,
            _str_batch(List[String](["a", "b"]), FORM_DICT),
            2,
            pool,
            res,
        ),
        "",
    )


def test_a_string_table_that_is_full_or_denied_is_refused_by_name() raises:
    var pool = SegmentPool()
    var res = WorkerReservation(pool.share())
    # A table of one string: a string seen again is not a second entry.
    var one = DistinctSlot(1, max_strings=1)
    assert_equal(
        _read_error(
            one, 0, _str_batch(List[String](["a", "a", NULL_STR])), 3, pool, res
        ),
        "",
    )
    assert_equal(
        _read_error(
            one, 0, _str_batch(List[String](["a", "b"])), 2, pool, res
        ),
        _too_many(1),
    )
    # A pool with no room denies the first step of the table.
    var none = SegmentPool(0)
    var none_res = WorkerReservation(none.share())
    var denied = DistinctSlot(1)
    assert_equal(
        _read_error(
            denied, 0, _str_batch(List[String](["a"])), 1, none, none_res
        ),
        _denied(64 * 28, 0, 0),
    )


def test_a_null_row_admits_nothing_and_an_entry_is_made_once() raises:
    var pool = SegmentPool()
    var res = WorkerReservation(pool.share())
    var slot = DistinctSlot(2)
    var col = _read(slot, 0, _int_batch(List[Int]([NUL, 4, 4])), pool, res)
    _admit(slot, 0, 0, col, 0, pool, res)
    assert_equal(slot.pairs.n, 0)
    _admit(slot, 0, 0, col, 1, pool, res)
    assert_equal(slot.pairs.n, 1)
    # The same value of the same group and aggregate is the same entry.
    _admit(slot, 0, 0, col, 2, pool, res)
    assert_equal(slot.pairs.n, 1)
    # Another group, and another aggregate, are other entries.
    _admit(slot, 0, 1, col, 1, pool, res)
    assert_equal(slot.pairs.n, 2)
    var other = _read(slot, 1, _int_batch(List[Int]([4])), pool, res)
    _admit(slot, 1, 0, other, 0, pool, res)
    assert_equal(slot.pairs.n, 3)


def test_a_table_of_entries_holds_its_limit_and_refuses_one_more() raises:
    var pool = SegmentPool()
    var res = WorkerReservation(pool.share())
    var slot = DistinctSlot(1, 64)
    var col = _read(slot, 0, _range_batch(65), pool, res)
    for r in range(64):
        _admit(slot, 0, 0, col, r, pool, res)
    assert_equal(slot.pairs.n, 64)
    # A value that is held is found without growing the table.
    assert_equal(_admit_error(slot, 0, 0, col, 63, pool, res), "")
    assert_equal(_admit_error(slot, 0, 0, col, 64, pool, res), _too_many(64))
    assert_equal(slot.pairs.n, 64)


def test_a_pool_that_denies_the_entries_is_refused_by_exact_message() raises:
    var pool = SegmentPool()
    var res = WorkerReservation(pool.share())
    var slot = DistinctSlot(1)
    var col = _read(slot, 0, _range_batch(2), pool, res)
    var none = SegmentPool(0)
    var none_res = WorkerReservation(none.share())
    assert_equal(
        _admit_error(slot, 0, 0, col, 0, none, none_res),
        _denied(_entries_bytes(), 0, 0),
    )
    assert_equal(slot.pairs.n, 0)


def test_a_merge_counts_each_value_once_in_each_merged_group() raises:
    var pool = SegmentPool()
    var res_a = WorkerReservation(pool.share())
    var res_b = WorkerReservation(pool.share())
    # Aggregate 0 is an integer and aggregate 1 a string. Worker A's groups 0
    # and 1 hold {1, 2} and {1}; worker B's group 0 holds {2, 3}. Worker B
    # numbers the strings differently: z, w, y against x, y.
    var a = DistinctSlot(2)
    _fill(a, 0, _int_batch(List[Int]([1, 2, 1])), List[Int]([0, 0, 1]), pool, res_a)
    _fill(
        a,
        1,
        _str_batch(List[String](["x", "y", "y"])),
        List[Int]([0, 0, 1]),
        pool,
        res_a,
    )
    var b = DistinctSlot(2)
    _fill(b, 0, _int_batch(List[Int]([2, 3])), List[Int]([0, 0]), pool, res_b)
    _fill(
        b,
        1,
        _str_batch(List[String](["z", "w", "y", NULL_STR])),
        List[Int]([0, 0, 0, 0]),
        pool,
        res_b,
    )
    var merge = DistinctMerge(2, WorkerReservation(pool.share()))
    # A's groups 0 and 1 are merged groups 0 and 1, B's group 0 is merged
    # group 1.
    var cells = _new_cells(4)
    _merge(merge, a, List[Int]([0, 1]), cells, 2, pool)
    _merge(merge, b, List[Int]([1]), cells, 2, pool)
    # Merged group 0: integers {1, 2}, strings {x, y}.
    assert_equal(cells[0].count, 2)
    assert_equal(cells[1].count, 2)
    # Merged group 1: integers {1} and {2, 3} make {1, 2, 3}; strings {y}
    # and {z, w, y} make {y, z, w}.
    assert_equal(cells[2].count, 3)
    assert_equal(cells[3].count, 3)


def test_a_merge_refuses_an_aggregate_that_changed_type_between_workers() raises:
    var pool = SegmentPool()
    var res_a = WorkerReservation(pool.share())
    var res_b = WorkerReservation(pool.share())
    var ints = _int_slot(List[Int]([1, 2]), List[Int]([0, 0]), pool, res_a, 2)
    var strs = DistinctSlot(2)
    _fill(
        strs,
        0,
        _str_batch(List[String](["a"])),
        List[Int]([0]),
        pool,
        res_b,
    )
    var merge = DistinctMerge(2, WorkerReservation(pool.share()))
    var cells = _new_cells(2)
    _merge(merge, ints, List[Int]([0]), cells, 2, pool)
    assert_equal(cells[0].count, 2)
    assert_equal(
        _merge_error(merge, strs, List[Int]([0]), cells, 2, pool),
        "pipeline_exec: " + String(LABEL)
        + " saw columns of different types on different workers",
    )
    # A worker that read nothing for any aggregate is no other type and adds
    # nothing.
    var idle = DistinctSlot(2)
    _merge(merge, idle, List[Int](), cells, 2, pool)
    assert_equal(cells[0].count, 2)
    assert_equal(cells[1].count, 0)


def test_a_merge_table_that_is_full_is_refused_by_name() raises:
    var pool = SegmentPool()
    var res = WorkerReservation(pool.share())
    # 64 values fit a merge of 64 entries; 65 do not.
    var fits = _int_slot(_range_list(64), _repeat(0, 64), pool, res)
    var merge = DistinctMerge(1, WorkerReservation(pool.share()), 64)
    var cells = _new_cells(1)
    _merge(merge, fits, List[Int]([0]), cells, 1, pool)
    assert_equal(cells[0].count, 64)
    var over = _int_slot(_range_list(65), _repeat(0, 65), pool, res)
    var merge65 = DistinctMerge(1, WorkerReservation(pool.share()), 64)
    var cells65 = _new_cells(1)
    assert_equal(
        _merge_error(merge65, over, List[Int]([0]), cells65, 1, pool),
        _too_many(64),
    )
    # A table of one string: the same string twice is one entry.
    var twice = DistinctSlot(1)
    _fill(
        twice,
        0,
        _str_batch(List[String](["a", "a"])),
        List[Int]([0, 1]),
        pool,
        res,
    )
    var merge_one = DistinctMerge(
        1, WorkerReservation(pool.share()), max_strings=1
    )
    var cells_one = _new_cells(2)
    _merge(merge_one, twice, List[Int]([0, 1]), cells_one, 1, pool)
    assert_equal(cells_one[0].count, 1)
    assert_equal(cells_one[1].count, 1)
    var two = DistinctSlot(1)
    _fill(
        two,
        0,
        _str_batch(List[String](["a", "b"])),
        List[Int]([0, 0]),
        pool,
        res,
    )
    var merge_two = DistinctMerge(
        1, WorkerReservation(pool.share()), max_strings=1
    )
    var cells_two = _new_cells(1)
    assert_equal(
        _merge_error(merge_two, two, List[Int]([0]), cells_two, 1, pool),
        _too_many(1),
    )


def test_a_merge_the_pool_denies_is_refused_by_exact_message() raises:
    var pool = SegmentPool()
    var res = WorkerReservation(pool.share())
    var none = SegmentPool(0)
    var ints = _int_slot(List[Int]([1, 2]), List[Int]([0, 0]), pool, res)
    var merge = DistinctMerge(1, WorkerReservation(none.share()))
    var cells = _new_cells(1)
    assert_equal(
        _merge_error(merge, ints, List[Int]([0]), cells, 1, none),
        _denied(_entries_bytes(), 0, 0),
    )
    # The merged strings are drawn first.
    var strs = DistinctSlot(1)
    _fill(
        strs,
        0,
        _str_batch(List[String](["a"])),
        List[Int]([0]),
        pool,
        res,
    )
    var merge_strs = DistinctMerge(1, WorkerReservation(none.share()))
    var cells_strs = _new_cells(1)
    assert_equal(
        _merge_error(merge_strs, strs, List[Int]([0]), cells_strs, 1, none),
        _denied(64 * 28, 0, 0),
    )


def test_finish_returns_the_merge_memory_and_empties_its_tables() raises:
    var pool = SegmentPool(1 << 20)
    var res = WorkerReservation(pool.share())
    var slot = DistinctSlot(1)
    _fill(
        slot,
        0,
        _str_batch(List[String](["a", "b", "c"])),
        List[Int]([0, 0, 1]),
        pool,
        res,
    )
    var merge = DistinctMerge(1, WorkerReservation(pool.share()))
    var cells = _new_cells(2)
    var before = pool.granted()
    _merge(merge, slot, List[Int]([0, 1]), cells, 1, pool)
    assert_true(pool.granted() > before, "the merge drew nothing")
    assert_equal(merge.pairs.n, 3)
    assert_equal(merge.values.n, 3)
    merge.finish()
    assert_equal(pool.granted(), before)
    assert_equal(merge.pairs.n, 0)
    assert_equal(merge.values.n, 0)
    # The counts are in the cells.
    assert_equal(cells[0].count, 2)
    assert_equal(cells[1].count, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
