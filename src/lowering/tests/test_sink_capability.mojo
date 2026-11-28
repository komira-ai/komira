# =============================================================================
# test_sink_capability: the table lowering admits against
# =============================================================================
#
# The table is data. These tests state its rows, the triples that must stay
# unserved (each a sink or key shape nothing runs yet), that a key type prints
# its name (an unknown tag prints its number), and that admission names the
# segment and the triple it refuses.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from containers.slab import Slab
from lowering.lowered_plan import LOWERING_SINK_UNSERVED
from lowering.sink_capability import (
    admit_plan,
    admit_segment,
    is_sink_served,
    key_dtype_name,
    sink_capability,
    triple_name,
)
from physical_plan.physical_plan import (
    SegmentDescPod,
    SourceSpecPod,
    MorselOp,
    SINK_AGG,
    SINK_SORT,
    SINK_TOPN,
    SINK_PARTITION_TOPN,
    SINK_COLLECT,
    SINK_HASH_BUILD,
    SINK_ASOF_JOIN,
    SINK_PARTITION_TOPN,
    SINK_ORIENT_COLUMNAR,
    SINK_ORIENT_DICT_ENCODED,
    KEY_DTYPE_NONE,
    KEY_DTYPE_I64,
    KEY_DTYPE_STRING,
    KEY_DTYPE_DATE32,
    KEY_DTYPE_BOOL,
    KEY_DTYPE_DECIMAL128,
    KEY_DTYPE_COMPOSITE,
)


def _segment(
    seg_id: Int, sink_kind: UInt8, key: UInt8, orientation: UInt8
) -> SegmentDescPod:
    return SegmentDescPod(
        seg_id,
        UInt8(2),
        SourceSpecPod.from_sink_output(0),
        Slab[MorselOp](),
        sink_kind,
        key,
        orientation,
        -1,
        seg_id,
        List[Int](),
        List[UInt8](),
    )


def test_the_table_holds_exactly_these_rows_in_this_order() raises:
    var rows = sink_capability()
    var got = String()
    for i in range(len(rows)):
        got += triple_name(rows[i].sink_kind, rows[i].key_dtype, rows[i].orientation) + "\n"
    var expected = String()
    expected += "(SINK_AGG, NONE, COLUMNAR)\n"
    expected += "(SINK_AGG, I64, COLUMNAR)\n"
    expected += "(SINK_AGG, I32, COLUMNAR)\n"
    expected += "(SINK_AGG, F64, COLUMNAR)\n"
    expected += "(SINK_AGG, F32, COLUMNAR)\n"
    expected += "(SINK_AGG, STRING, DICT_ENCODED)\n"
    expected += "(SINK_AGG, STRING, COLUMNAR)\n"
    expected += "(SINK_AGG, DATE32, COLUMNAR)\n"
    expected += "(SINK_AGG, BOOL, COLUMNAR)\n"
    expected += "(SINK_AGG, DECIMAL128, COLUMNAR)\n"
    expected += "(SINK_AGG, COMPOSITE, COLUMNAR)\n"
    expected += "(SINK_SORT, NONE, COLUMNAR)\n"
    expected += "(SINK_TOPN, NONE, COLUMNAR)\n"
    expected += "(SINK_PARTITION_BY, NONE, COLUMNAR)\n"
    expected += "(SINK_COLLECT, NONE, COLUMNAR)\n"
    expected += "(SINK_HASH_BUILD, NONE, COLUMNAR)\n"
    expected += "(SINK_ASOF_JOIN, NONE, COLUMNAR)\n"
    assert_equal(got, expected)


def test_no_row_repeats_and_none_spills() raises:
    var rows = sink_capability()
    for i in range(len(rows)):
        assert_false(rows[i].spillable)
        for j in range(i + 1, len(rows)):
            var same = (
                rows[i].sink_kind == rows[j].sink_kind
                and rows[i].key_dtype == rows[j].key_dtype
                and rows[i].orientation == rows[j].orientation
            )
            assert_false(same)


def test_every_row_is_served_and_nearby_triples_are_not() raises:
    var rows = sink_capability()
    for i in range(len(rows)):
        assert_true(is_sink_served(rows[i].sink_kind, rows[i].key_dtype, rows[i].orientation))
    assert_false(is_sink_served(SINK_PARTITION_TOPN, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR))
    assert_false(is_sink_served(SINK_TOPN, KEY_DTYPE_I64, SINK_ORIENT_COLUMNAR))
    assert_false(is_sink_served(SINK_TOPN, KEY_DTYPE_NONE, SINK_ORIENT_DICT_ENCODED))
    assert_false(is_sink_served(SINK_HASH_BUILD, KEY_DTYPE_I64, SINK_ORIENT_COLUMNAR))
    assert_false(is_sink_served(SINK_ASOF_JOIN, KEY_DTYPE_I64, SINK_ORIENT_COLUMNAR))
    assert_false(is_sink_served(SINK_ASOF_JOIN, KEY_DTYPE_NONE, SINK_ORIENT_DICT_ENCODED))
    assert_false(is_sink_served(SINK_AGG, KEY_DTYPE_I64, SINK_ORIENT_DICT_ENCODED))
    assert_false(is_sink_served(SINK_AGG, KEY_DTYPE_NONE, SINK_ORIENT_DICT_ENCODED))
    assert_false(is_sink_served(SINK_COLLECT, KEY_DTYPE_I64, SINK_ORIENT_COLUMNAR))
    assert_false(is_sink_served(SINK_SORT, KEY_DTYPE_STRING, SINK_ORIENT_COLUMNAR))
    assert_false(is_sink_served(SINK_AGG, KEY_DTYPE_DATE32, SINK_ORIENT_DICT_ENCODED))
    assert_false(is_sink_served(SINK_AGG, KEY_DTYPE_BOOL, SINK_ORIENT_DICT_ENCODED))
    assert_false(is_sink_served(SINK_AGG, KEY_DTYPE_DECIMAL128, SINK_ORIENT_DICT_ENCODED))
    assert_false(is_sink_served(SINK_SORT, KEY_DTYPE_DATE32, SINK_ORIENT_COLUMNAR))
    assert_false(is_sink_served(SINK_COLLECT, KEY_DTYPE_BOOL, SINK_ORIENT_COLUMNAR))
    assert_false(is_sink_served(SINK_HASH_BUILD, KEY_DTYPE_DECIMAL128, SINK_ORIENT_COLUMNAR))
    assert_false(is_sink_served(SINK_AGG, KEY_DTYPE_COMPOSITE, SINK_ORIENT_DICT_ENCODED))
    assert_false(is_sink_served(SINK_SORT, KEY_DTYPE_COMPOSITE, SINK_ORIENT_COLUMNAR))


def test_a_key_type_prints_its_name_and_an_unknown_tag_prints_its_number() raises:
    assert_equal(key_dtype_name(KEY_DTYPE_DATE32), "DATE32")
    assert_equal(key_dtype_name(KEY_DTYPE_BOOL), "BOOL")
    assert_equal(key_dtype_name(KEY_DTYPE_DECIMAL128), "DECIMAL128")
    assert_equal(key_dtype_name(KEY_DTYPE_STRING), "STRING")
    assert_equal(key_dtype_name(KEY_DTYPE_COMPOSITE), "COMPOSITE")
    assert_equal(key_dtype_name(UInt8(10)), "KEY_10")


def test_admission_passes_a_served_segment_and_names_an_unserved_one() raises:
    admit_segment(_segment(0, SINK_AGG, KEY_DTYPE_STRING, SINK_ORIENT_DICT_ENCODED))
    var message = String()
    try:
        admit_segment(_segment(4, SINK_PARTITION_TOPN, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR))
    except e:
        message = String(e)
    assert_true(message.startswith(String(LOWERING_SINK_UNSERVED) + ": segment 4 "), message)
    assert_true("(SINK_PARTITION_TOPN, NONE, COLUMNAR)" in message, message)


def test_admitting_a_plan_stops_at_the_first_unserved_segment() raises:
    var ok = List[SegmentDescPod]()
    ok.append(_segment(0, SINK_AGG, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR))
    ok.append(_segment(1, SINK_SORT, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR))
    ok.append(_segment(2, SINK_TOPN, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR))
    admit_plan(ok)

    var mixed = List[SegmentDescPod]()
    mixed.append(_segment(0, SINK_AGG, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR))
    mixed.append(_segment(1, SINK_PARTITION_TOPN, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR))
    mixed.append(_segment(2, SINK_TOPN, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR))
    var message = String()
    try:
        admit_plan(mixed)
    except e:
        message = String(e)
    assert_true(": segment 1 " in message, message)
    assert_true("(SINK_PARTITION_TOPN, NONE, COLUMNAR)" in message, message)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
