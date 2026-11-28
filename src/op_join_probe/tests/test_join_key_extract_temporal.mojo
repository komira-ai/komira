# DATE and TIMESTAMP join keys: a DATE32 key is its midnight in microseconds,
# so it meets a microsecond TIMESTAMP key as DuckDB's implicit cast does;
# DATE64 and every TIMESTAMP unit (int64) are compared by their storage, and
# only against a key of the SAME arrow type.
#
#   test_date32_key_slots_are_each_midnight_in_microseconds
#       a DATE32 key column renders to Int64 slots holding each day's midnight
#       in microseconds (a day before the epoch stays negative) and a NULL row
#       to the NULL sentinel.
#   test_a_date32_key_beyond_the_timestamp_range_is_refused
#       the first and last days whose midnight is a microsecond TIMESTAMP
#       render; one day past either end raises, naming the column.
#   test_timestamp_us_key_slots_are_the_microseconds
#       a TIMESTAMP_US key renders to its microsecond values, a NULL row to the
#       sentinel; a column without a validity bitmap renders to the same slots.
#   test_every_temporal_type_extracts_as_a_key
#       DATE64, TIMESTAMP, TIMESTAMP_S, TIMESTAMP_MS, TIMESTAMP_US and
#       TIMESTAMP_NS columns each extract to their storage values.
#   test_same_type_temporal_pairs_compare_as_stored
#       a pair of two keys of one temporal type (TIMESTAMP and TIMESTAMP_US
#       count as one) is not promoted to FLOAT64.
#   test_temporal_pair_of_two_types_is_refused_by_name
#       every pair of two different temporal types raises, naming both keys
#       and both types.
#   test_date32_against_int32_is_refused
#       DATE32 against INT32 raises with the exact message, in both directions.
#   test_timestamp_us_against_int64_float64_or_string_is_refused
#       TIMESTAMP_US against INT64, FLOAT64 and STRING raises.
#   test_date32_against_timestamp_us_compares_as_microseconds
#       the pair is neither refused nor promoted to FLOAT64, in both
#       directions; DATE32 against another TIMESTAMP unit is refused.
#   test_date32_key_join_matches_equal_days_only
#       build + probe through MultiKeyHashJoinBuilder and MultiKeyJoinProbeOp:
#       equal days match, a different day and a NULL key (either side) do not.
#   test_timestamp_us_key_join_matches_equal_instants_only
#       the same join over TIMESTAMP_US: equal microseconds match, a value one
#       microsecond apart and NULL keys do not.
#   test_a_date32_key_meets_a_timestamp_us_key_at_midnight
#       build + probe of DATE32 against TIMESTAMP_US, both ways round: a day
#       matches its midnight, not a microsecond after it, and NULL keys match
#       nothing.

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.record_batch import RecordBatch, RecordBatchBuilder
from arrow.schema import Field, Schema, SchemaBuilder
from arrow.string_array import StringArray
from byte_buffer.heap_region import HeapRegion
from containers.slab import Slab
from morsel.morsel import Morsel, split_record_batch
from plan_ir.logical_plan import JOIN_INNER

from op_join_probe.join_key_extract import (
    extract_join_key_columns_serial,
    join_key_pairs_as_float64,
)
from op_join_probe.join_multi_key import _NAN_SENTINEL_BITS
from op_join_probe.join_multi_key_builder import MultiKeyHashJoinBuilder
from op_join_probe.multi_key_probe_op import MultiKeyJoinProbeOp

comptime I64 = DType.int64
comptime I32 = DType.int32


def _col64(
    vals: List[Int64], at: ArrowType, null_at: List[Int] = List[Int]()
) raises -> Column[HeapRegion]:
    """An int64-storage column of arrow type `at`; with `null_at` it carries a
    validity bitmap with those rows NULL."""
    if len(null_at) == 0:
        return Column.from_primitive_with_arrow_type[I64](
            PrimitiveArray[I64].from_list(vals), at
        )
    var arr = PrimitiveArray[I64].allocate_nullable(len(vals))
    var p = arr._typed_ptr_mut()
    for i in range(len(vals)):
        p.store[width=1](i, vals[i])
    for k in range(len(null_at)):
        arr._set_null(null_at[k])
    return Column.from_primitive_with_arrow_type[I64](arr, at)


def _col32(
    vals: List[Int32], at: ArrowType, null_at: List[Int] = List[Int]()
) raises -> Column[HeapRegion]:
    """The int32-storage twin of `_col64`."""
    var arr = PrimitiveArray[I32].allocate_nullable(len(vals))
    var p = arr._typed_ptr_mut()
    for i in range(len(vals)):
        p.store[width=1](i, vals[i])
    for k in range(len(null_at)):
        arr._set_null(null_at[k])
    return Column.from_primitive_with_arrow_type[I32](arr, at)


def _ids(n: Int) raises -> Column[HeapRegion]:
    var ids = List[Int64]()
    for i in range(n):
        ids.append(Int64(i))
    return Column.from_primitive[I64](PrimitiveArray[I64].from_list(ids))


def _batch(
    name: String, at: ArrowType, var key: Column[HeapRegion], id: String
) raises -> RecordBatch:
    """Key column `name` of type `at`, then `id` (0, 1, ...)."""
    var n = key.length()
    var sb = SchemaBuilder()
    sb.add_field(Field(name, at, True))
    sb.add_field(Field(id, ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(key^)
    rb.add_column(_ids(n))
    return rb.build(sb.build())


def _key_only(
    at: ArrowType, var key: Column[HeapRegion]
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", at, True))
    var rb = RecordBatchBuilder()
    rb.add_column(key^)
    return rb.build(sb.build())


def _pair_error(
    probe: RecordBatch, build: RecordBatch
) raises -> String:
    """The message `join_key_pairs_as_float64` raises for the pair ('k', 'k'),
    or "" when it does not raise."""
    try:
        _ = join_key_pairs_as_float64(probe, ["k"], build, ["k"])
    except e:
        return String(e)
    return String("")


def _out_schema(imm probe: RecordBatch, imm build: RecordBatch) raises -> Schema:
    var sb = SchemaBuilder()
    for c in range(probe.num_columns()):
        sb.add_field(
            Field(
                "p_" + probe.schema.field_name(c),
                probe.schema.field_arrow_type(c),
                True,
            )
        )
    for c in range(build.num_columns()):
        sb.add_field(
            Field(
                "b_" + build.schema.field_name(c),
                build.schema.field_arrow_type(c),
                True,
            )
        )
    return sb.build()


def _join(
    var probe: RecordBatch, var build: RecordBatch
) raises -> List[Int64]:
    """INNER join of key `k` against key `bk` through the builder and the
    operator the pipeline uses; each output row as
    `(probe id + 1) * 100 + (build id + 1)`, sorted."""
    var pkeys: List[String] = ["k"]
    var bkeys: List[String] = ["bk"]
    var schema = _out_schema(probe, build)
    var builder = MultiKeyHashJoinBuilder.build(
        extract_join_key_columns_serial(build, bkeys)
    )
    var op = MultiKeyJoinProbeOp(
        ArcPointer[MultiKeyHashJoinBuilder](builder^),
        ArcPointer[RecordBatch](build^),
        pkeys.copy(),
        bkeys.copy(),
        ArcPointer[Schema](schema^),
        JOIN_INNER,
    )
    var morsels = split_record_batch(probe^, 1)
    var slab = Slab[Morsel]()
    morsels.drain_morsels_into(slab)
    var out = List[Int64]()
    for i in range(len(slab)):
        _ = op.execute(slab[i])
        ref b = slab[i].batch
        if b.num_rows() == 0:
            continue
        var p = b.column_at(b.schema.column_index("p_pid")).as_primitive[I64]()
        var q = b.column_at(b.schema.column_index("b_bid")).as_primitive[I64]()
        for r in range(p.length):
            out.append((p.get(r) + 1) * 100 + (q.get(r) + 1))
    sort(out)
    return out^


def test_date32_key_slots_are_each_midnight_in_microseconds() raises:
    var batch = _key_only(
        ArrowType.DATE32,
        _col32([Int32(19723), Int32(-1), Int32(0)], ArrowType.DATE32, [2]),
    )
    var keys = extract_join_key_columns_serial(batch, ["k"])
    ref k0 = keys.int_keys.value()[0]
    assert_equal(k0.get(0), Int64(1704067200000000), "2024-01-01 at midnight")
    assert_equal(
        k0.get(1), Int64(-86400000000), "a day before the epoch stays negative"
    )
    assert_true(k0.is_null(2), "the NULL row keeps its validity")
    assert_equal(k0.get(2), _NAN_SENTINEL_BITS, "the NULL row is the sentinel")
    assert_equal(k0.null_count, 1, "null count")


def _date32_key_error(day: Int32) raises -> String:
    """The message extracting a one-row DATE32 key `k` of `day` raises, or ""
    when it renders."""
    var batch = _key_only(ArrowType.DATE32, _col32([day], ArrowType.DATE32))
    try:
        _ = extract_join_key_columns_serial(batch, ["k"])
    except e:
        return String(e)
    return String("")


def test_a_date32_key_beyond_the_timestamp_range_is_refused() raises:
    assert_equal(_date32_key_error(Int32(106751991)), "")
    assert_equal(_date32_key_error(Int32(-106751991)), "")
    assert_equal(
        _date32_key_error(Int32(106751992)),
        "join key column 'k': the DATE 106751992 days from 1970-01-01 is"
        " beyond the TIMESTAMP range a DATE key is compared in",
    )
    assert_true(
        "the DATE -106751992 days" in _date32_key_error(Int32(-106751992)),
        "the first day before the range",
    )


def test_timestamp_us_key_slots_are_the_microseconds() raises:
    var vals: List[Int64] = [1704067200000000, 1704067200000001, 0]
    var nullable = _key_only(
        ArrowType.TIMESTAMP_US, _col64(vals, ArrowType.TIMESTAMP_US, [2])
    )
    var keys = extract_join_key_columns_serial(nullable, ["k"])
    ref k0 = keys.int_keys.value()[0]
    assert_equal(k0.get(0), Int64(1704067200000000), "row 0")
    assert_equal(k0.get(1), Int64(1704067200000001), "row 1")
    assert_equal(k0.get(2), _NAN_SENTINEL_BITS, "NULL row")
    var plain = _key_only(
        ArrowType.TIMESTAMP_US, _col64(vals, ArrowType.TIMESTAMP_US)
    )
    var keys2 = extract_join_key_columns_serial(plain, ["k"])
    ref p0 = keys2.int_keys.value()[0]
    assert_equal(p0.get(0), Int64(1704067200000000), "no-bitmap row 0")
    assert_equal(p0.get(1), Int64(1704067200000001), "no-bitmap row 1")
    assert_false(p0.validity.__bool__(), "no bitmap stays no bitmap")


def test_every_temporal_type_extracts_as_a_key() raises:
    var types: List[ArrowType] = [
        ArrowType.DATE64,
        ArrowType.TIMESTAMP,
        ArrowType.TIMESTAMP_S,
        ArrowType.TIMESTAMP_MS,
        ArrowType.TIMESTAMP_US,
        ArrowType.TIMESTAMP_NS,
    ]
    for t in range(len(types)):
        var batch = _key_only(
            types[t], _col64([Int64(7), Int64(-9)], types[t])
        )
        var keys = extract_join_key_columns_serial(batch, ["k"])
        ref k0 = keys.int_keys.value()[0]
        assert_equal(k0.get(0), Int64(7), "row 0 of type " + String(types[t]))
        assert_equal(k0.get(1), Int64(-9), "row 1 of type " + String(types[t]))


def test_same_type_temporal_pairs_compare_as_stored() raises:
    var d = _key_only(ArrowType.DATE32, _col32([Int32(1)], ArrowType.DATE32))
    assert_false(
        join_key_pairs_as_float64(d, ["k"], d, ["k"])[0], "DATE32 pair"
    )
    var t = _key_only(
        ArrowType.TIMESTAMP, _col64([Int64(1)], ArrowType.TIMESTAMP)
    )
    var u = _key_only(
        ArrowType.TIMESTAMP_US, _col64([Int64(1)], ArrowType.TIMESTAMP_US)
    )
    assert_false(
        join_key_pairs_as_float64(t, ["k"], u, ["k"])[0],
        "TIMESTAMP and TIMESTAMP_US are both microseconds",
    )
    assert_false(
        join_key_pairs_as_float64(u, ["k"], t, ["k"])[0], "and the reverse"
    )


def test_temporal_pair_of_two_types_is_refused_by_name() raises:
    var types: List[ArrowType] = [
        ArrowType.DATE64,
        ArrowType.TIMESTAMP_S,
        ArrowType.TIMESTAMP_MS,
        ArrowType.TIMESTAMP_US,
        ArrowType.TIMESTAMP_NS,
    ]
    for a in range(len(types)):
        for b in range(len(types)):
            if a == b:
                continue
            var pa = _key_only(types[a], _col64([Int64(1)], types[a]))
            var pb = _key_only(types[b], _col64([Int64(1)], types[b]))
            assert_equal(
                _pair_error(pa, pb),
                "join key pair ('k', 'k'): a " + String(types[a])
                + " key cannot be compared with a " + String(types[b])
                + " key without an explicit cast",
            )
    var d32 = _key_only(ArrowType.DATE32, _col32([Int32(1)], ArrowType.DATE32))
    var d64 = _key_only(ArrowType.DATE64, _col64([Int64(1)], ArrowType.DATE64))
    assert_true(
        "cannot be compared" in _pair_error(d32, d64), "DATE32 against DATE64"
    )


def test_date32_against_int32_is_refused() raises:
    var d = _key_only(ArrowType.DATE32, _col32([Int32(1)], ArrowType.DATE32))
    var i = _key_only(ArrowType.INT32, _col32([Int32(1)], ArrowType.INT32))
    var dt = String(ArrowType.DATE32)
    var it = String(ArrowType.INT32)
    assert_equal(
        _pair_error(d, i),
        "join key pair ('k', 'k'): a " + dt + " key cannot be compared with a "
        + it + " key without an explicit cast",
    )
    assert_equal(
        _pair_error(i, d),
        "join key pair ('k', 'k'): a " + it + " key cannot be compared with a "
        + dt + " key without an explicit cast",
    )


def test_timestamp_us_against_int64_float64_or_string_is_refused() raises:
    var t = _key_only(
        ArrowType.TIMESTAMP_US, _col64([Int64(1)], ArrowType.TIMESTAMP_US)
    )
    var i = _key_only(ArrowType.INT64, _col64([Int64(1)], ArrowType.INT64))
    var f = _key_only(
        ArrowType.FLOAT64,
        Column.from_primitive[DType.float64](
            PrimitiveArray[DType.float64].from_list([Float64(1.0)])
        ),
    )
    var s = _key_only(
        ArrowType.STRING,
        Column.from_string(StringArray.from_strings(["1"])),
    )
    assert_true("cannot be compared" in _pair_error(t, i), "TIMESTAMP_US, INT64")
    assert_true("cannot be compared" in _pair_error(i, t), "INT64, TIMESTAMP_US")
    assert_true("cannot be compared" in _pair_error(t, f), "TIMESTAMP_US, FLOAT64")
    assert_true("cannot be compared" in _pair_error(f, t), "FLOAT64, TIMESTAMP_US")
    assert_true("cannot be compared" in _pair_error(t, s), "TIMESTAMP_US, STRING")
    assert_true("cannot be compared" in _pair_error(s, t), "STRING, TIMESTAMP_US")


def test_date32_against_timestamp_us_compares_as_microseconds() raises:
    var d = _key_only(ArrowType.DATE32, _col32([Int32(1)], ArrowType.DATE32))
    var t = _key_only(
        ArrowType.TIMESTAMP_US, _col64([Int64(1)], ArrowType.TIMESTAMP_US)
    )
    var legacy = _key_only(
        ArrowType.TIMESTAMP, _col64([Int64(1)], ArrowType.TIMESTAMP)
    )
    assert_false(join_key_pairs_as_float64(d, ["k"], t, ["k"])[0], "DATE32, TS_US")
    assert_false(join_key_pairs_as_float64(t, ["k"], d, ["k"])[0], "TS_US, DATE32")
    assert_equal(_pair_error(d, legacy), "")
    var ms = _key_only(
        ArrowType.TIMESTAMP_MS, _col64([Int64(1)], ArrowType.TIMESTAMP_MS)
    )
    assert_equal(
        _pair_error(d, ms),
        "join key pair ('k', 'k'): a " + String(ArrowType.DATE32)
        + " key cannot be compared with a " + String(ArrowType.TIMESTAMP_MS)
        + " key without an explicit cast",
    )
    assert_true("cannot be compared" in _pair_error(ms, d), "reverse")


def test_date32_key_join_matches_equal_days_only() raises:
    var probe = _batch(
        "k", ArrowType.DATE32,
        _col32(
            [Int32(19723), Int32(19724), Int32(19725), Int32(19726)],
            ArrowType.DATE32, [3],
        ),
        "pid",
    )
    var build = _batch(
        "bk", ArrowType.DATE32,
        _col32(
            [Int32(19725), Int32(19723), Int32(19999), Int32(19726)],
            ArrowType.DATE32, [3],
        ),
        "bid",
    )
    var got = _join(probe^, build^)
    assert_equal(len(got), 2, "rows")
    assert_equal(got[0], 102, "probe 0 (19723) with build 1")
    assert_equal(got[1], 301, "probe 2 (19725) with build 0; NULL keys match nothing")


def test_timestamp_us_key_join_matches_equal_instants_only() raises:
    var base: Int64 = 1704067200000000
    var probe = _batch(
        "k", ArrowType.TIMESTAMP_US,
        _col64(
            [base, base + 1, base + 86400000000, base + 5],
            ArrowType.TIMESTAMP_US, [3],
        ),
        "pid",
    )
    var build = _batch(
        "bk", ArrowType.TIMESTAMP_US,
        _col64(
            [base + 86400000000, base, base + 2, base + 5],
            ArrowType.TIMESTAMP_US, [3],
        ),
        "bid",
    )
    var got = _join(probe^, build^)
    assert_equal(len(got), 2, "rows")
    assert_equal(got[0], 102, "probe 0 (base) with build 1")
    assert_equal(got[1], 301, "probe 2 (base + 1 day) with build 0")


def test_a_date32_key_meets_a_timestamp_us_key_at_midnight() raises:
    var base: Int64 = 1704067200000000  # 2024-01-01 00:00:00
    var day: Int64 = 86400000000
    # Probe days 2024-01-01, 01-02 and a NULL; build the first midnight, one
    # microsecond after it, 01-02's midnight and a NULL.
    var got = _join(
        _batch(
            "k", ArrowType.DATE32,
            _col32([Int32(19723), Int32(19724), Int32(19723)], ArrowType.DATE32, [2]),
            "pid",
        ),
        _batch(
            "bk", ArrowType.TIMESTAMP_US,
            _col64([base, base + 1, base + day, base], ArrowType.TIMESTAMP_US, [3]),
            "bid",
        ),
    )
    assert_equal(len(got), 2, "rows")
    assert_equal(got[0], 101, "2024-01-01 with its midnight")
    assert_equal(got[1], 203, "2024-01-02 with its midnight")
    # The other way round: TIMESTAMP_US probe keys against DATE32 build keys.
    var back = _join(
        _batch(
            "k", ArrowType.TIMESTAMP_US,
            _col64([base + day, base + 1, base], ArrowType.TIMESTAMP_US),
            "pid",
        ),
        _batch(
            "bk", ArrowType.DATE32,
            _col32([Int32(19723), Int32(19724)], ArrowType.DATE32),
            "bid",
        ),
    )
    assert_equal(len(back), 2, "rows")
    assert_equal(back[0], 102, "01-02's midnight with 2024-01-02")
    assert_equal(back[1], 301, "01-01's midnight with 2024-01-01")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
