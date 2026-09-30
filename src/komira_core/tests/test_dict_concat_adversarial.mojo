# =============================================================================
# ADVERSARIAL VERIFICATION of the DictInterner dictionary merge
# =============================================================================
#
# `test_dict_concat_probe_bound.mojo` exercises the merge only through
# SINGLE-COLUMN batches whose dictionary column is therefore always at index 0,
# and its one DICTIONARY-vs-STRING equivalence oracle uses DISJOINT per-batch
# dictionaries — so no lookup in it ever HITS an existing entry. This file adds
# the cases that structure leaves out:
#
#   * the dictionary column FIRST / MIDDLE / LAST in a multi-column batch
#   * TWO dictionary columns in one batch, with different dictionaries
#   * the OTHER `any_slow` trigger, BOOL, alone and beside a dictionary
#   * OVERLAPPING dictionaries driven through `_concat_variable_width_batches`
#     and checked against the STRING path on the same logical values, which is
#     where a remap bug lives (a disjoint merge never takes the `found` branch)
# =============================================================================

from std.memory import alloc
from std.sys import size_of
from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.column import Column
from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.dictionary_array import StringDictionaryArray
from komira_core.arrow.schema import Field, RecordBatch, Schema, SchemaBuilder
from komira_core.arrow.string_array import StringArray
from komira_core.arrow_helpers.streaming_concat import (
    _concat_variable_width_batches,
)
from komira_core.io.heap_region import HeapRegion


# =============================================================================
# builders
# =============================================================================


def _dict_col(
    dict_values: List[String], indices: List[Int32]
) raises -> Column[HeapRegion]:
    comptime int32_size = size_of[Int32]()
    var dict_arr = StringArray.from_strings(dict_values)
    var n = len(indices)
    var idx_buf = OwnedAlignedBuffer(max(n * int32_size, 1))
    for i in range(n):
        idx_buf.set_typed[Int32](i, indices[i])
    idx_buf.set_length(Int64(n * int32_size))
    var idx_arr = PrimitiveArray[DType.int32](idx_buf^, n, None, 0, 0)
    var sda = StringDictionaryArray(idx_arr^, dict_arr^, n)
    return Column.from_dictionary(sda)


def _str_col(values: List[String]) raises -> Column[HeapRegion]:
    return Column.from_string(StringArray.from_strings(values)^)


def _bool_col(values: List[Bool]) raises -> Column[HeapRegion]:
    var arr = BooleanArray.allocate(len(values))
    for i in range(len(values)):
        if values[i]:
            arr.data.set(i)
    return Column.from_boolean(arr)


def _schema3(
    n0: String, t0: ArrowType, n1: String, t1: ArrowType, n2: String, t2: ArrowType
) raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(n0, t0, False))
    sb.add_field(Field(n1, t1, False))
    sb.add_field(Field(n2, t2, False))
    return sb.build()


def _resolve_dict(c: Column[HeapRegion]) raises -> List[String]:
    var out = List[String]()
    for i in range(c._length):
        var code = Int(c._data.get_typed[Int32](i))
        var bv = c.string_dict_value_at(code)
        var buf = List[UInt8](capacity=bv.len() + 1)
        bv.copy_to(buf, 0, bv.len())
        buf.append(UInt8(0))
        # SAFETY: `buf` outlives the String ctor, which copies.
        out.append(String(unsafe_from_utf8_ptr=buf.unsafe_ptr()))
    return out^


def _resolve_str(c: Column[HeapRegion]) raises -> List[String]:
    var out = List[String]()
    var sa = c.as_string()
    for i in range(c._length):
        out.append(String(sa.get(i)))
    return out^


# The three per-batch dictionaries used throughout. They OVERLAP partially,
# a value present in batch 1 is absent from batch 0, and a value reappears in
# batch 2 after being introduced in batch 0 — the shapes a remap bug corrupts.
#   b0: alpha bravo charlie      rows: alpha bravo charlie alpha
#   b1: delta bravo              rows: delta bravo delta
#   b2: charlie echo alpha       rows: echo alpha charlie
comptime N_B = 3


def _dv(k: Int) raises -> List[String]:
    if k == 0:
        return [String("alpha"), String("bravo"), String("charlie")]
    if k == 1:
        return [String("delta"), String("bravo")]
    return [String("charlie"), String("echo"), String("alpha")]


def _di(k: Int) raises -> List[Int32]:
    if k == 0:
        return [Int32(0), Int32(1), Int32(2), Int32(0)]
    if k == 1:
        return [Int32(0), Int32(1), Int32(0)]
    return [Int32(1), Int32(2), Int32(0)]


def _rows(k: Int) raises -> List[String]:
    """The same values `_dv(k)`/`_di(k)` denote, as plain strings."""
    var d = _dv(k)
    var idx = _di(k)
    var out = List[String]()
    for i in range(len(idx)):
        out.append(d[Int(idx[i])].copy())
    return out^


def _expected_all() raises -> List[String]:
    var out = List[String]()
    for k in range(N_B):
        var r = _rows(k)
        for i in range(len(r)):
            out.append(r[i].copy())
    return out^


# =============================================================================
# THE DICTIONARY COLUMN'S POSITION MUST NOT MATTER
# =============================================================================


def _run_position_case(dict_pos: Int) raises:
    """3-column batches; the DICTIONARY column sits at `dict_pos`, the other
    two are STRING. Every column must survive the fold with correct values."""
    var staging = alloc[Optional[RecordBatch]](N_B)
    for k in range(N_B):
        var rows = _rows(k)
        var n = len(rows)
        var left = List[String]()
        var right = List[String]()
        for i in range(n):
            left.append(String("L") + String(k) + String("_") + String(i))
            right.append(String("R") + String(k) + String("_") + String(i))

        var dcol = _dict_col(_dv(k), _di(k))
        var batch: RecordBatch
        if dict_pos == 0:
            batch = RecordBatch.from_typed_columns_3(
                _schema3(
                    "d", ArrowType.DICTIONARY, "l", ArrowType.STRING,
                    "r", ArrowType.STRING,
                )^,
                dcol^, _str_col(left)^, _str_col(right)^,
            )
        elif dict_pos == 1:
            batch = RecordBatch.from_typed_columns_3(
                _schema3(
                    "l", ArrowType.STRING, "d", ArrowType.DICTIONARY,
                    "r", ArrowType.STRING,
                )^,
                _str_col(left)^, dcol^, _str_col(right)^,
            )
        else:
            batch = RecordBatch.from_typed_columns_3(
                _schema3(
                    "l", ArrowType.STRING, "r", ArrowType.STRING,
                    "d", ArrowType.DICTIONARY,
                )^,
                _str_col(left)^, _str_col(right)^, dcol^,
            )
        (staging + k).unsafe_write(Optional[RecordBatch](batch^))

    var out = _concat_variable_width_batches(staging, N_B)
    staging.free()

    var expect = _expected_all()
    assert_equal(out.num_rows(), len(expect), "row count")

    ref dc = out.column_at(dict_pos)
    assert_equal(
        dc.arrow_type,
        ArrowType.DICTIONARY,
        String("column ") + String(dict_pos) + String(" stays DICTIONARY"),
    )
    var got = _resolve_dict(dc)
    for i in range(len(expect)):
        assert_equal(
            got[i],
            expect[i],
            String("dict at pos ") + String(dict_pos) + String(" row ") + String(i),
        )

    # The STRING neighbours must be untouched by the dictionary column's
    # presence -- they ride the same pair-wise fold once `any_slow` trips.
    var lpos = 1 if dict_pos == 0 else 0
    var rpos = 2 if dict_pos != 2 else 1
    var lgot = _resolve_str(out.column_at(lpos))
    var rgot = _resolve_str(out.column_at(rpos))
    var w = 0
    for k in range(N_B):
        var n = len(_rows(k))
        for i in range(n):
            assert_equal(
                lgot[w], String("L") + String(k) + String("_") + String(i), "L"
            )
            assert_equal(
                rgot[w], String("R") + String(k) + String("_") + String(i), "R"
            )
            w += 1


def test_dict_column_first() raises:
    _run_position_case(0)


def test_dict_column_middle() raises:
    _run_position_case(1)


def test_dict_column_last() raises:
    _run_position_case(2)


# =============================================================================
# TWO DICTIONARY COLUMNS IN ONE BATCH
# =============================================================================


def test_two_dictionary_columns_merge_independently() raises:
    """Each dictionary column must get its OWN merged dictionary. A merge that
    shared interner state across columns would cross-contaminate ordinals."""
    var staging = alloc[Optional[RecordBatch]](N_B)
    for k in range(N_B):
        # Second dictionary column: same INDEX stream, disjoint VALUES, so a
        # cross-column leak shows up as a value from the other column.
        var d2 = List[String]()
        var src = _dv(k)
        for i in range(len(src)):
            var out_s = String("X_") + src[i]
            d2.append(out_s^)
        var batch = RecordBatch.from_typed_columns_3(
            _schema3(
                "d1", ArrowType.DICTIONARY, "mid", ArrowType.STRING,
                "d2", ArrowType.DICTIONARY,
            )^,
            _dict_col(_dv(k), _di(k))^,
            _str_col(_rows(k))^,
            _dict_col(d2, _di(k))^,
        )
        (staging + k).unsafe_write(Optional[RecordBatch](batch^))

    var out = _concat_variable_width_batches(staging, N_B)
    staging.free()

    var expect = _expected_all()
    var g1 = _resolve_dict(out.column_at(0))
    var g2 = _resolve_dict(out.column_at(2))
    var gmid = _resolve_str(out.column_at(1))
    assert_equal(len(g1), len(expect), "d1 rows")
    assert_equal(len(g2), len(expect), "d2 rows")
    for i in range(len(expect)):
        assert_equal(g1[i], expect[i], String("d1 row ") + String(i))
        assert_equal(
            g2[i], String("X_") + expect[i], String("d2 row ") + String(i)
        )
        assert_equal(gmid[i], expect[i], String("mid row ") + String(i))

    # Independent dictionaries: 5 distinct in each, never 10 in either.
    assert_equal(out.column_at(0)._dict_size, 5, "d1 cardinality")
    assert_equal(out.column_at(2)._dict_size, 5, "d2 cardinality")


# =============================================================================
# THE OTHER `any_slow` TRIGGER: BOOL
# =============================================================================


def _bools(k: Int) raises -> List[Bool]:
    var rows = _rows(k)
    var out = List[Bool]()
    for i in range(len(rows)):
        out.append((k + i) % 2 == 0)
    return out^


def test_bool_column_triggers_slow_path_and_stays_correct() raises:
    """BOOL alone trips `any_slow`. The bit-packed fold must still produce the
    right bits -- this arm has no dictionary in it at all."""
    var staging = alloc[Optional[RecordBatch]](N_B)
    for k in range(N_B):
        var sb = SchemaBuilder()
        sb.add_field(Field("b", ArrowType.BOOL, False))
        sb.add_field(Field("s", ArrowType.STRING, False))
        var batch = RecordBatch.from_typed_columns_2(
            sb.build()^, _bool_col(_bools(k))^, _str_col(_rows(k))^
        )
        (staging + k).unsafe_write(Optional[RecordBatch](batch^))

    var out = _concat_variable_width_batches(staging, N_B)
    staging.free()

    var expect = _expected_all()
    var ba = out.column_at(0).as_boolean()
    var gs = _resolve_str(out.column_at(1))
    var w = 0
    for k in range(N_B):
        var bs = _bools(k)
        for i in range(len(bs)):
            assert_equal(ba.get(w), bs[i], String("bool row ") + String(w))
            assert_equal(gs[w], expect[w], String("str row ") + String(w))
            w += 1
    assert_equal(w, len(expect), "row count")


def test_bool_and_dictionary_in_one_batch() raises:
    """Both `any_slow` triggers at once, dictionary LAST."""
    var staging = alloc[Optional[RecordBatch]](N_B)
    for k in range(N_B):
        var batch = RecordBatch.from_typed_columns_3(
            _schema3(
                "b", ArrowType.BOOL, "s", ArrowType.STRING,
                "d", ArrowType.DICTIONARY,
            )^,
            _bool_col(_bools(k))^,
            _str_col(_rows(k))^,
            _dict_col(_dv(k), _di(k))^,
        )
        (staging + k).unsafe_write(Optional[RecordBatch](batch^))

    var out = _concat_variable_width_batches(staging, N_B)
    staging.free()

    var expect = _expected_all()
    var ba = out.column_at(0).as_boolean()
    var gd = _resolve_dict(out.column_at(2))
    var w = 0
    for k in range(N_B):
        var bs = _bools(k)
        for i in range(len(bs)):
            assert_equal(ba.get(w), bs[i], String("bool row ") + String(w))
            assert_equal(gd[w], expect[w], String("dict row ") + String(w))
            w += 1


# =============================================================================
# THE EQUIVALENCE ORACLE, WITH OVERLAP
# =============================================================================


def test_overlapping_dicts_match_plain_string_path() raises:
    """The one-bit-flip control where it actually discriminates.

    `test_dict_concat_matches_plain_control` uses DISJOINT
    per-batch dictionaries, so `find_or_insert` never returns an EXISTING
    ordinal and the remap table is the identity-plus-offset. With overlapping
    dictionaries every hit exercises the remap, which is the branch a
    hash-map rewrite gets wrong silently.
    """
    var dict_staging = alloc[Optional[RecordBatch]](N_B)
    var plain_staging = alloc[Optional[RecordBatch]](N_B)
    for k in range(N_B):
        var sbd = SchemaBuilder()
        sbd.add_field(Field("v", ArrowType.DICTIONARY, False))
        (dict_staging + k).unsafe_write(
            Optional[RecordBatch](
                RecordBatch.from_typed_columns_1(
                    sbd.build()^, _dict_col(_dv(k), _di(k))^
                )
            )
        )
        var sbp = SchemaBuilder()
        sbp.add_field(Field("v", ArrowType.STRING, False))
        (plain_staging + k).unsafe_write(
            Optional[RecordBatch](
                RecordBatch.from_typed_columns_1(
                    sbp.build()^, _str_col(_rows(k))^
                )
            )
        )

    var dout = _concat_variable_width_batches(dict_staging, N_B)
    var pout = _concat_variable_width_batches(plain_staging, N_B)
    dict_staging.free()
    plain_staging.free()

    var gd = _resolve_dict(dout.column_at(0))
    var gp = _resolve_str(pout.column_at(0))
    var expect = _expected_all()
    assert_equal(len(gd), len(expect), "dict arm rows")
    assert_equal(len(gp), len(expect), "plain arm rows")
    for i in range(len(expect)):
        assert_equal(gd[i], gp[i], String("ARM-DICT vs ARM-PLAIN row ") + String(i))
        assert_equal(gd[i], expect[i], String("ARM-DICT vs expected row ") + String(i))

    # Dedup actually happened: 5 distinct values across 8 dictionary entries.
    assert_equal(dout.column_at(0)._dict_size, 5, "merged cardinality")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
