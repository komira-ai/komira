"""The public surface of `komira_op_agg_row_api`, pinned by value.

Every name here crosses a package boundary: the hash tables, the sinks, the
dispatch and the typed sources agree on these values without sharing any other
code, so a drift in one of them is a wrong answer somewhere else, not a compile
error. Each case states the defect it catches.
"""

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_column_format.column_format_storage import (
    DT_I64,
    DT_DATE64,
    DT_I32,
    DT_DATE32,
    DT_U32,
    DT_U64,
    DT_F64,
)
from komira_op_agg_row_api.agg_chunk_rows import (
    AGG_KBUF_CHUNK_DEFAULT_KIB,
    agg_kbuf_chunk_rows,
)
from komira_op_agg_row_api.agg_key_class import (
    VEC_MIN_DIR_CAP,
    ingest_key_mono_class,
    IKM_NONE,
    IKM_I64,
    IKM_I32,
    IKM_U32,
)
from komira_op_agg_row_api.agg_spec import (
    AggSpec,
    AGG_NONE,
    AGG_SUM_I64,
    AGG_SUM_F64,
    AGG_COUNT,
    AGG_MIN_I64,
    AGG_MAX_I64,
    AGG_MIN_F64,
    AGG_MAX_F64,
    AGG_AVG_F64,
    AGG_STDDEV_POP_F64,
    AGG_STDDEV_SAMP_F64,
    AGG_VAR_SAMP_F64,
    AGG_MIN_U64,
    AGG_MAX_U64,
    AGG_MIN_STR,
    AGG_MAX_STR,
    AGG_SUM_I128,
    AGG_SUM_U128,
    AGG_AVG_I128,
    dtype_is_integer,
    is_exact_sum_op,
    is_minmax_i64_family,
    is_minmax_str_op,
    is_minmax_u64_op,
    merge_cell_class,
)
from komira_op_agg_row_api.combine_agg_plan import (
    MC_NONE,
    MC_ADD_U64,
    MC_ADD_F64,
    MC_MIN_I64,
    MC_MAX_I64,
    MC_MIN_F64,
    MC_MAX_F64,
    MC_AVG_F64,
    MC_ADD_I128,
    MC_AVG_I128,
)


def _all_tags() -> List[UInt8]:
    """Every `AGG_*` tag, in value order (index i holds the tag of value i)."""
    var t = List[UInt8]()
    t.append(AGG_NONE)
    t.append(AGG_SUM_I64)
    t.append(AGG_SUM_F64)
    t.append(AGG_COUNT)
    t.append(AGG_MIN_I64)
    t.append(AGG_MAX_I64)
    t.append(AGG_MIN_F64)
    t.append(AGG_MAX_F64)
    t.append(AGG_AVG_F64)
    t.append(AGG_STDDEV_POP_F64)
    t.append(AGG_STDDEV_SAMP_F64)
    t.append(AGG_VAR_SAMP_F64)
    t.append(AGG_MIN_U64)
    t.append(AGG_MAX_U64)
    t.append(AGG_MIN_STR)
    t.append(AGG_MAX_STR)
    t.append(AGG_SUM_I128)
    t.append(AGG_SUM_U128)
    t.append(AGG_AVG_I128)
    return t^


def test_agg_tags_are_the_values_zero_to_eighteen() raises:
    """The tags are a contract between the planner that writes them into
    `AggSpec.op_tag` and every kernel ladder that dispatches on them. Two tags
    sharing a value would send one op down the other's arm; a renumbered tag
    would desynchronise any package built against the old value."""
    var t = _all_tags()
    assert_equal(len(t), 19, "19 op tags")
    for i in range(len(t)):
        assert_equal(Int(t[i]), i, "tag at position " + String(i))


def _expected_class(i: Int) -> Int:
    """The merge-cell class of the tag of value `i`, written out by hand from
    the merge ladder's arms (not computed from `merge_cell_class`)."""
    if i == 1 or i == 3:  # SUM_I64, COUNT: one 64-bit add
        return MC_ADD_U64
    if i == 2:  # SUM_F64
        return MC_ADD_F64
    if i == 4 or i == 12:  # MIN_I64 and the biased MIN_U64
        return MC_MIN_I64
    if i == 5 or i == 13:  # MAX_I64 and the biased MAX_U64
        return MC_MAX_I64
    if i == 6:  # MIN_F64
        return MC_MIN_F64
    if i == 7:  # MAX_F64
        return MC_MAX_F64
    if i == 8:  # AVG_F64
        return MC_AVG_F64
    if i == 16 or i == 17:  # SUM_I128, SUM_U128: one exact 128-bit add
        return MC_ADD_I128
    if i == 18:  # AVG_I128
        return MC_AVG_I128
    # NONE, STDDEV_POP, STDDEV_SAMP, VAR_SAMP, MIN_STR, MAX_STR: no
    # monomorphic combine kernel; the combine declines to the checked ladder.
    return MC_NONE


def test_merge_cell_class_maps_every_tag_arm_for_arm() raises:
    """A tag mapped to the wrong class merges with the wrong kernel and produces
    a wrong number with no crash (a MIN merged as a MAX, an exact 128-bit sum
    merged as a 64-bit add). Every one of the 19 tags is pinned."""
    var t = _all_tags()
    for i in range(len(t)):
        assert_equal(
            merge_cell_class(t[i]),
            _expected_class(i),
            "merge class of the tag of value " + String(i),
        )


def test_merge_cell_class_declines_the_ops_with_no_monomorphic_merge() raises:
    """The Welford ops merge through a three-cell formula, STDDEV_POP is not
    combine-stable at all, and the string cells hold arena offsets: each must
    decline (`MC_NONE`) so the combine keeps the checked ladder for it."""
    assert_equal(merge_cell_class(AGG_STDDEV_POP_F64), MC_NONE, "STDDEV_POP")
    assert_equal(merge_cell_class(AGG_STDDEV_SAMP_F64), MC_NONE, "STDDEV_SAMP")
    assert_equal(merge_cell_class(AGG_VAR_SAMP_F64), MC_NONE, "VAR_SAMP")
    assert_equal(merge_cell_class(AGG_MIN_STR), MC_NONE, "MIN_STR")
    assert_equal(merge_cell_class(AGG_MAX_STR), MC_NONE, "MAX_STR")
    assert_equal(merge_cell_class(AGG_NONE), MC_NONE, "NONE")
    assert_equal(merge_cell_class(UInt8(200)), MC_NONE, "an unknown tag")


def test_op_predicates_accept_exactly_their_tags() raises:
    """Each predicate guards a cell-level ladder against reading a cell of the
    same width as something else (an arena offset or the low word of a 128-bit
    integer read as a double, a biased cell published without un-biasing).
    Each is checked against all 19 tags, so a predicate that also accepted a
    neighbour is caught, not only one that missed its own tags."""
    var t = _all_tags()
    for i in range(len(t)):
        var tag = t[i]
        var label = " for the tag of value " + String(i)
        assert_equal(
            is_exact_sum_op(tag),
            tag == AGG_SUM_I128 or tag == AGG_SUM_U128,
            "is_exact_sum_op" + label,
        )
        assert_equal(
            is_minmax_str_op(tag),
            tag == AGG_MIN_STR or tag == AGG_MAX_STR,
            "is_minmax_str_op" + label,
        )
        assert_equal(
            is_minmax_u64_op(tag),
            tag == AGG_MIN_U64 or tag == AGG_MAX_U64,
            "is_minmax_u64_op" + label,
        )
        assert_equal(
            is_minmax_i64_family(tag),
            tag == AGG_MIN_I64
            or tag == AGG_MAX_I64
            or tag == AGG_MIN_U64
            or tag == AGG_MAX_U64,
            "is_minmax_i64_family" + label,
        )


def test_dtype_is_integer_is_the_eight_fixed_width_integers() raises:
    """It gates AVG over dictionary codes to integer aggregands, whose sums are
    exact in any order; admitting a float would make the answer depend on the
    fold order."""
    assert_true(dtype_is_integer(DType.int8), "int8")
    assert_true(dtype_is_integer(DType.int16), "int16")
    assert_true(dtype_is_integer(DType.int32), "int32")
    assert_true(dtype_is_integer(DType.int64), "int64")
    assert_true(dtype_is_integer(DType.uint8), "uint8")
    assert_true(dtype_is_integer(DType.uint16), "uint16")
    assert_true(dtype_is_integer(DType.uint32), "uint32")
    assert_true(dtype_is_integer(DType.uint64), "uint64")
    assert_false(dtype_is_integer(DType.float32), "float32")
    assert_false(dtype_is_integer(DType.float64), "float64")
    assert_false(dtype_is_integer(DType.bool), "bool")


def test_agg_spec_is_a_plain_value() raises:
    """`AggSpec` is copied into every table and sink. A copy must carry all four
    fields and stay independent of the original."""
    var a = AggSpec(
        op_tag=AGG_AVG_F64,
        src_col_idx=3,
        state_byte_width=UInt16(16),
        state_offset_in_slot=0,
    )
    var b = a
    b.op_tag = AGG_COUNT
    b.src_col_idx = -1
    b.state_byte_width = UInt16(8)
    b.state_offset_in_slot = 8
    assert_equal(a.op_tag, AGG_AVG_F64, "original op_tag")
    assert_equal(a.src_col_idx, 3, "original src_col_idx")
    assert_equal(a.state_byte_width, UInt16(16), "original state_byte_width")
    assert_equal(a.state_offset_in_slot, 0, "original state_offset_in_slot")
    assert_equal(b.op_tag, AGG_COUNT, "copy op_tag")
    assert_equal(b.src_col_idx, -1, "copy src_col_idx")
    assert_equal(b.state_byte_width, UInt16(8), "copy state_byte_width")
    assert_equal(b.state_offset_in_slot, 8, "copy state_offset_in_slot")


def test_shipped_constants_and_the_default_window() raises:
    """The two tuning constants, and the window the shipped budget gives on a
    122,880-row batch: 256 KiB / ((nk + 1) * 8 B) rows, i.e. 16,384 rows for one
    key and 4,681 for six (the figures the constant's docstring quotes)."""
    assert_equal(VEC_MIN_DIR_CAP, 1024, "VEC_MIN_DIR_CAP")
    assert_equal(AGG_KBUF_CHUNK_DEFAULT_KIB, 256, "AGG_KBUF_CHUNK_DEFAULT_KIB")
    assert_equal(
        agg_kbuf_chunk_rows(AGG_KBUF_CHUNK_DEFAULT_KIB, 1, 122_880),
        16_384,
        "1 key",
    )
    assert_equal(
        agg_kbuf_chunk_rows(AGG_KBUF_CHUNK_DEFAULT_KIB, 6, 122_880),
        4_681,
        "6 keys",
    )
    assert_equal(
        agg_kbuf_chunk_rows(AGG_KBUF_CHUNK_DEFAULT_KIB, 1, 16_384),
        16_384,
        "a batch exactly one window long is one window",
    )
    assert_equal(
        agg_kbuf_chunk_rows(AGG_KBUF_CHUNK_DEFAULT_KIB, 1, -5),
        -5,
        "a non-positive row count is returned unchanged",
    )


def _one(t0: UInt8) -> List[UInt8]:
    var l = List[UInt8]()
    l.append(t0)
    return l^


def _three(t0: UInt8, t1: UInt8, t2: UInt8) -> List[UInt8]:
    var l = List[UInt8]()
    l.append(t0)
    l.append(t1)
    l.append(t2)
    return l^


def test_ingest_key_class_single_and_three_key_batches() raises:
    """The class is decided on the first key and confirmed on every other one;
    a check that looked only at the first key or only at two keys would hand a
    mixed batch a monomorphic probe that widens the other keys wrongly."""
    assert_equal(ingest_key_mono_class(_one(DT_I64)), IKM_I64, "one I64")
    assert_equal(ingest_key_mono_class(_one(DT_DATE32)), IKM_I32, "one DATE32")
    assert_equal(ingest_key_mono_class(_one(DT_U32)), IKM_U32, "one U32")
    assert_equal(ingest_key_mono_class(_one(DT_U64)), IKM_NONE, "one U64")
    assert_equal(ingest_key_mono_class(_one(DT_F64)), IKM_NONE, "one F64")
    assert_equal(
        ingest_key_mono_class(_three(DT_DATE64, DT_I64, DT_DATE64)),
        IKM_I64,
        "three 8-byte signed keys",
    )
    assert_equal(
        ingest_key_mono_class(_three(DT_I32, DT_I32, DT_U32)),
        IKM_NONE,
        "the third key differs",
    )
    assert_equal(
        ingest_key_mono_class(_three(DT_U32, DT_U32, DT_I64)),
        IKM_NONE,
        "the third key differs in width",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_agg_tags_are_the_values_zero_to_eighteen]()
    suite.test[test_merge_cell_class_maps_every_tag_arm_for_arm]()
    suite.test[test_merge_cell_class_declines_the_ops_with_no_monomorphic_merge]()
    suite.test[test_op_predicates_accept_exactly_their_tags]()
    suite.test[test_dtype_is_integer_is_the_eight_fixed_width_integers]()
    suite.test[test_agg_spec_is_a_plain_value]()
    suite.test[test_shipped_constants_and_the_default_window]()
    suite.test[test_ingest_key_class_single_and_three_key_batches]()
    suite^.run()
