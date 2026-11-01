# Composite joins over DICTIONARY string keys: the extract's side channels
# and fingerprints; same-dictionary keys compared by index; different
# dictionaries compared by bytes; DICT against STRING; NULL dictionary keys.

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_buffer.byte_view import ByteView

from komira_op_join_probe.join_multi_key import (
    MultiKeyColumns,
)
from komira_op_join_probe.join_key_extract import (
    extract_join_key_columns_serial,
)
from komira_op_join_probe.join_multi_key_builder import (
    MultiKeyHashJoinBuilder,
)
from komira_op_join_probe.join_multi_key_filter import (
    multi_key_probe_semi,
    multi_key_probe_anti,
)
from komira_buffer.heap_region import HeapRegion


def _make_int64_col(name: String, values: List[Int]) raises -> Column[HeapRegion]:
    var n = len(values)
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, Scalar[DType.int64](values[i]))
    return Column.from_primitive(arr^)


def _make_string_col(name: String, values: List[String]) raises -> Column[HeapRegion]:
    var sa = StringArray.from_strings(values)
    return Column.from_string(sa^)


def _make_dict_col(
    name: String,
    indices: List[Int],
    dictionary: List[String],
) raises -> Column[HeapRegion]:
    """Build a DICT-encoded column."""
    var n = len(indices)
    var idx_arr = PrimitiveArray[DType.int32].allocate(n)
    var p = idx_arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, Scalar[DType.int32](indices[i]))
    var dict_sa = StringArray.from_strings(dictionary)
    var dict_arr = StringDictionaryArray.from_parts(idx_arr^, dict_sa^)
    return Column.from_dictionary(dict_arr)


def _make_dict_col_with_nulls(
    name: String,
    indices: List[Int],
    null_mask: List[Bool],
    dictionary: List[String],
) raises -> Column[HeapRegion]:
    """Build a DICT-encoded column with explicit per-row nulls."""
    from std.sys import size_of
    comptime int32_size = size_of[Int32]()

    var n = len(indices)
    var idx_arr = PrimitiveArray[DType.int32].allocate_nullable(n)
    var p = idx_arr._typed_ptr_mut()
    var null_count = 0
    for i in range(n):
        if null_mask[i]:
            null_count += 1
            idx_arr.validity.value().clear(i)
            p.store[width=1](i, Scalar[DType.int32](0))
        else:
            idx_arr.validity.value().set(i)
            p.store[width=1](i, Scalar[DType.int32](indices[i]))
    idx_arr.null_count = null_count

    var dict_sa = StringArray.from_strings(dictionary)
    var dict_arr = StringDictionaryArray.from_parts(idx_arr^, dict_sa^)
    return Column.from_dictionary(dict_arr)


def _make_2col_dict_dict(
    c0_name: String, c1_name: String,
    c0_idx: List[Int], c0_dict: List[String],
    c1_idx: List[Int], c1_dict: List[String],
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(c0_name, ArrowType.DICTIONARY, False))
    sb.add_field(Field(c1_name, ArrowType.DICTIONARY, False))
    var schema = sb.build()
    var bldr = RecordBatchBuilder()
    bldr.add_column(_make_dict_col(c0_name, c0_idx, c0_dict))
    bldr.add_column(_make_dict_col(c1_name, c1_idx, c1_dict))
    return bldr.build(schema^)


def _make_2col_dict_int64(
    c0_name: String, c1_name: String,
    c0_idx: List[Int], c0_dict: List[String],
    c1_values: List[Int],
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(c0_name, ArrowType.DICTIONARY, False))
    sb.add_field(Field(c1_name, ArrowType.INT64, False))
    var schema = sb.build()
    var bldr = RecordBatchBuilder()
    bldr.add_column(_make_dict_col(c0_name, c0_idx, c0_dict))
    bldr.add_column(_make_int64_col(c1_name, c1_values))
    return bldr.build(schema^)


def _make_2col_dict_string(
    c0_name: String, c1_name: String,
    c0_idx: List[Int], c0_dict: List[String],
    c1_values: List[String],
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(c0_name, ArrowType.DICTIONARY, False))
    sb.add_field(Field(c1_name, ArrowType.STRING, False))
    var schema = sb.build()
    var bldr = RecordBatchBuilder()
    bldr.add_column(_make_dict_col(c0_name, c0_idx, c0_dict))
    bldr.add_column(_make_string_col(c1_name, c1_values))
    return bldr.build(schema^)


def _make_2col_string_string_for_dict_compare(
    c0_name: String, c1_name: String,
    c0_values: List[String], c1_values: List[String],
) raises -> RecordBatch:
    """A two-key batch of the given key columns."""
    var sb = SchemaBuilder()
    sb.add_field(Field(c0_name, ArrowType.STRING, False))
    sb.add_field(Field(c1_name, ArrowType.STRING, False))
    var schema = sb.build()
    var bldr = RecordBatchBuilder()
    bldr.add_column(_make_string_col(c0_name, c0_values))
    bldr.add_column(_make_string_col(c1_name, c1_values))
    return bldr.build(schema^)


def _make_2col_dict_dict_with_nulls(
    c0_name: String, c1_name: String,
    c0_idx: List[Int], c0_nulls: List[Bool], c0_dict: List[String],
    c1_idx: List[Int], c1_nulls: List[Bool], c1_dict: List[String],
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(c0_name, ArrowType.DICTIONARY, True))
    sb.add_field(Field(c1_name, ArrowType.DICTIONARY, True))
    var schema = sb.build()
    var bldr = RecordBatchBuilder()
    bldr.add_column(_make_dict_col_with_nulls(c0_name, c0_idx, c0_nulls, c0_dict))
    bldr.add_column(_make_dict_col_with_nulls(c1_name, c1_idx, c1_nulls, c1_dict))
    return bldr.build(schema^)


def _direct_inner_probe(
    var build_keys: MultiKeyColumns,
    var probe_keys: MultiKeyColumns,
) raises -> Tuple[List[Int], List[Int]]:
    var builder = MultiKeyHashJoinBuilder.build(build_keys^)
    var bm = List[Int]()
    var pm = List[Int]()
    builder.probe_inner_into(probe_keys, bm, pm)
    return (bm^, pm^)


def _direct_left_probe(
    var build_keys: MultiKeyColumns,
    var probe_keys: MultiKeyColumns,
) raises -> Tuple[List[Int], List[Int]]:
    var builder = MultiKeyHashJoinBuilder.build(build_keys^)
    var bm = List[Int]()
    var pm = List[Int]()
    builder.probe_left_into(probe_keys, bm, pm)
    return (bm^, pm^)


def test_extract_helper_accepts_dict_dtype() raises:
    """DICT keys are accepted by `extract_join_key_columns_typed`."""
    var sb = SchemaBuilder()
    sb.add_field(Field("ik", ArrowType.INT64, False))
    sb.add_field(Field("dk", ArrowType.DICTIONARY, False))
    var schema = sb.build()
    var ik_vals: List[Int] = [1, 2, 3]
    var dk_idx: List[Int] = [0, 1, 0]
    var dk_dict: List[String] = ["alpha", "beta"]
    var bldr = RecordBatchBuilder()
    bldr.add_column(_make_int64_col("ik", ik_vals))
    bldr.add_column(_make_dict_col("dk", dk_idx, dk_dict))
    var batch = bldr.build(schema^)

    var keys = List[String]()
    keys.append("ik")
    keys.append("dk")

    var bundle = extract_join_key_columns_serial(batch, keys)
    assert_equal(bundle.num_keys, 2)
    assert_equal(bundle.int_keys.value()[0].length, 3)
    assert_equal(bundle.int_keys.value()[1].length, 3)
    assert_false(bundle.string_keys.value()[0].__bool__())
    assert_true(bundle.string_keys.value()[1].__bool__())
    assert_false(bundle.dict_keys.value()[0].__bool__())
    assert_true(bundle.dict_keys.value()[1].__bool__())
    assert_equal(bundle.dict_fingerprints.value()[0], UInt64(0))
    assert_true(bundle.dict_fingerprints.value()[1] != UInt64(0))


def test_dict_dict_inner_same_dict() raises:
    """DICT + DICT INNER probe — same-dict fast path (matching fingerprints)."""
    var b_country_idx: List[Int] = [0, 1, 2]   # US, DE, JP
    var b_currency_idx: List[Int] = [0, 1, 2]  # USD, EUR, JPY
    var b_country_dict: List[String] = ["US", "DE", "JP"]
    var b_currency_dict: List[String] = ["USD", "EUR", "JPY"]
    var b = _make_2col_dict_dict(
        "country", "currency",
        b_country_idx, b_country_dict,
        b_currency_idx, b_currency_dict,
    )

    var p_country_idx: List[Int] = [0, 1, 2, 2]  # US, DE, JP, JP
    var p_currency_idx: List[Int] = [0, 0, 2, 2]  # USD, USD, JPY, JPY
    var p_country_dict: List[String] = ["US", "DE", "JP"]
    var p_currency_dict: List[String] = ["USD", "EUR", "JPY"]
    var p = _make_2col_dict_dict(
        "country", "currency",
        p_country_idx, p_country_dict,
        p_currency_idx, p_currency_dict,
    )

    var bk = List[String]()
    bk.append("country")
    bk.append("currency")
    var pk = List[String]()
    pk.append("country")
    pk.append("currency")

    var bks = extract_join_key_columns_serial(b, bk)
    var pks = extract_join_key_columns_serial(p, pk)
    var bm_pm = _direct_inner_probe(bks^, pks^)

    assert_equal(len(bm_pm[0]), 3)
    assert_equal(len(bm_pm[1]), 3)


def test_dict_dict_inner_cross_dict() raises:
    """DICT + DICT INNER probe — cross-dict fallback (different fingerprints)."""
    var b_country_idx: List[Int] = [0, 1, 2]
    var b_currency_idx: List[Int] = [0, 1, 2]
    var b_country_dict: List[String] = ["US", "DE", "JP"]
    var b_currency_dict: List[String] = ["USD", "EUR", "JPY"]
    var b = _make_2col_dict_dict(
        "country", "currency",
        b_country_idx, b_country_dict,
        b_currency_idx, b_currency_dict,
    )

    var p_country_dict: List[String] = ["FR", "DE", "JP", "US"]  # different ordering + extra
    var p_currency_dict: List[String] = ["GBP", "EUR", "JPY", "USD"]
    var p_country_idx: List[Int] = [3, 1, 2, 0]   # US, DE, JP, FR
    var p_currency_idx: List[Int] = [3, 3, 2, 0]  # USD, USD, JPY, GBP
    var p = _make_2col_dict_dict(
        "country", "currency",
        p_country_idx, p_country_dict,
        p_currency_idx, p_currency_dict,
    )

    var bk = List[String]()
    bk.append("country")
    bk.append("currency")
    var pk = List[String]()
    pk.append("country")
    pk.append("currency")

    var bks = extract_join_key_columns_serial(b, bk)
    var pks = extract_join_key_columns_serial(p, pk)
    var bm_pm = _direct_inner_probe(bks^, pks^)

    assert_equal(len(bm_pm[0]), 2)
    assert_equal(len(bm_pm[1]), 2)


def test_dict_dict_inner_same_dict_matches_cross_dict() raises:
    """The same-dict and cross-dict paths must produce the same logical results."""
    var b_a_idx: List[Int] = [0, 1, 2, 0, 1]  # alpha, beta, gamma, alpha, beta
    var b_b_idx: List[Int] = [0, 0, 1, 1, 0]  # x, x, y, y, x
    var dict_a: List[String] = ["alpha", "beta", "gamma"]
    var dict_b: List[String] = ["x", "y"]
    var b = _make_2col_dict_dict(
        "a", "b",
        b_a_idx, dict_a,
        b_b_idx, dict_b,
    )

    var p_a_idx: List[Int] = [0, 1, 2]  # alpha, beta, gamma
    var p_b_idx: List[Int] = [0, 0, 1]  # x, x, y
    var p_same = _make_2col_dict_dict(
        "a", "b",
        p_a_idx, dict_a,
        p_b_idx, dict_b,
    )

    var bk = List[String]()
    bk.append("a")
    bk.append("b")
    var pk = List[String]()
    pk.append("a")
    pk.append("b")

    var bks_same = extract_join_key_columns_serial(b, bk)
    var pks_same = extract_join_key_columns_serial(p_same, pk)
    var same_matches = _direct_inner_probe(bks_same^, pks_same^)

    var dict_a_p: List[String] = ["gamma", "alpha", "beta"]  # rotated
    var dict_b_p: List[String] = ["y", "x"]                  # swapped
    var p_a_idx_x: List[Int] = [1, 2, 0]
    var p_b_idx_x: List[Int] = [1, 1, 0]
    var b2 = _make_2col_dict_dict(
        "a", "b",
        b_a_idx, dict_a,
        b_b_idx, dict_b,
    )
    var p_cross = _make_2col_dict_dict(
        "a", "b",
        p_a_idx_x, dict_a_p,
        p_b_idx_x, dict_b_p,
    )
    var bks_cross = extract_join_key_columns_serial(b2, bk)
    var pks_cross = extract_join_key_columns_serial(p_cross, pk)
    var cross_matches = _direct_inner_probe(bks_cross^, pks_cross^)

    assert_equal(len(same_matches[0]), len(cross_matches[0]))
    assert_equal(len(same_matches[1]), len(cross_matches[1]))
    assert_equal(len(same_matches[0]), 4)


def test_dict_int64_mixed_inner() raises:
    """DICT + INT64 mixed multi-key INNER probe."""
    var b_name_idx: List[Int] = [0, 1, 2]
    var b_name_dict: List[String] = ["alice", "bob", "carol"]
    var b_id: List[Int] = [1, 2, 3]
    var b = _make_2col_dict_int64(
        "name", "id",
        b_name_idx, b_name_dict,
        b_id,
    )

    var p_name_idx: List[Int] = [0, 0, 1, 2]  # alice, alice, bob, carol
    var p_name_dict: List[String] = ["alice", "bob", "carol"]
    var p_id: List[Int] = [1, 2, 2, 99]
    var p = _make_2col_dict_int64(
        "name", "id",
        p_name_idx, p_name_dict,
        p_id,
    )

    var bk = List[String]()
    bk.append("name")
    bk.append("id")
    var pk = List[String]()
    pk.append("name")
    pk.append("id")

    var bks = extract_join_key_columns_serial(b, bk)
    var pks = extract_join_key_columns_serial(p, pk)
    var bm_pm = _direct_inner_probe(bks^, pks^)

    assert_equal(len(bm_pm[0]), 2)
    assert_equal(len(bm_pm[1]), 2)


def test_dict_string_mixed_inner() raises:
    """DICT + STRING mixed multi-key INNER probe."""
    var b_country_idx: List[Int] = [0, 1, 2]
    var b_country_dict: List[String] = ["US", "DE", "JP"]
    var b_currency: List[String] = ["USD", "EUR", "JPY"]
    var b = _make_2col_dict_string(
        "country", "currency",
        b_country_idx, b_country_dict,
        b_currency,
    )

    var p_country_idx: List[Int] = [0, 1, 2, 2]  # US, DE, JP, JP
    var p_country_dict: List[String] = ["US", "DE", "JP"]
    var p_currency: List[String] = ["USD", "USD", "JPY", "EUR"]
    var p = _make_2col_dict_string(
        "country", "currency",
        p_country_idx, p_country_dict,
        p_currency,
    )

    var bk = List[String]()
    bk.append("country")
    bk.append("currency")
    var pk = List[String]()
    pk.append("country")
    pk.append("currency")

    var bks = extract_join_key_columns_serial(b, bk)
    var pks = extract_join_key_columns_serial(p, pk)
    var bm_pm = _direct_inner_probe(bks^, pks^)

    assert_equal(len(bm_pm[0]), 2)


def test_dict_left_emits_unmatched() raises:
    """DICT + DICT LEFT: unmatched probe rows emit with build idx -1."""
    var b_a_idx: List[Int] = [0, 1]
    var b_b_idx: List[Int] = [0, 1]
    var dict_a: List[String] = ["x", "y"]
    var dict_b: List[String] = ["a", "b"]
    var b = _make_2col_dict_dict("a", "b", b_a_idx, dict_a, b_b_idx, dict_b)

    var p_a_idx: List[Int] = [0, 1, 0]  # x, y, x
    var p_b_idx: List[Int] = [0, 1, 1]  # a, b, b -- third row doesn't match
    var p = _make_2col_dict_dict("a", "b", p_a_idx, dict_a, p_b_idx, dict_b)

    var bk = List[String]()
    bk.append("a")
    bk.append("b")
    var pk = List[String]()
    pk.append("a")
    pk.append("b")

    var bks = extract_join_key_columns_serial(b, bk)
    var pks = extract_join_key_columns_serial(p, pk)
    var bm_pm = _direct_left_probe(bks^, pks^)

    assert_equal(len(bm_pm[0]), 3)
    assert_equal(len(bm_pm[1]), 3)

    var found_unmatched = False
    for i in range(3):
        if bm_pm[1][i] == 2:
            assert_equal(bm_pm[0][i], -1)
            found_unmatched = True
    assert_true(found_unmatched, "expected probe_idx=2 emitted with -1")


def test_dict_semi_returns_matched_probes() raises:
    """DICT + DICT SEMI: probe rows that have at least one match."""
    var b_a_idx: List[Int] = [0, 1]
    var b_b_idx: List[Int] = [0, 1]
    var dict_a: List[String] = ["red", "blue"]
    var dict_b: List[String] = ["car", "boat"]
    var b = _make_2col_dict_dict("a", "b", b_a_idx, dict_a, b_b_idx, dict_b)

    var p_a_idx: List[Int] = [0, 0, 1]    # red, red, blue
    var p_b_idx: List[Int] = [0, 1, 1]    # car, boat, boat
    var p = _make_2col_dict_dict("a", "b", p_a_idx, dict_a, p_b_idx, dict_b)

    var bk = List[String]()
    bk.append("a")
    bk.append("b")
    var pk = List[String]()
    pk.append("a")
    pk.append("b")

    var bks = extract_join_key_columns_serial(b, bk)
    var pks = extract_join_key_columns_serial(p, pk)
    var builder = MultiKeyHashJoinBuilder.build(bks^)
    var semi = multi_key_probe_semi(builder, pks)

    assert_equal(len(semi), 2)


def test_dict_anti_returns_unmatched_probes() raises:
    """DICT + DICT ANTI: probe rows that have NO match."""
    var b_a_idx: List[Int] = [0]
    var b_b_idx: List[Int] = [0]
    var dict_a: List[String] = ["solo"]
    var dict_b: List[String] = ["only"]
    var b = _make_2col_dict_dict("a", "b", b_a_idx, dict_a, b_b_idx, dict_b)

    var p_a_idx: List[Int] = [0, 1]  # solo, other
    var p_b_idx: List[Int] = [0, 0]  # only, only
    var p_dict_a: List[String] = ["solo", "other"]
    var p_dict_b: List[String] = ["only"]
    var p = _make_2col_dict_dict(
        "a", "b",
        p_a_idx, p_dict_a,
        p_b_idx, p_dict_b,
    )

    var bk = List[String]()
    bk.append("a")
    bk.append("b")
    var pk = List[String]()
    pk.append("a")
    pk.append("b")

    var bks = extract_join_key_columns_serial(b, bk)
    var pks = extract_join_key_columns_serial(p, pk)
    var builder = MultiKeyHashJoinBuilder.build(bks^)
    var anti = multi_key_probe_anti(builder, pks)

    assert_equal(len(anti), 1)
    assert_equal(anti[0], 1)


def test_dict_null_keys_no_match_inner() raises:
    """NULL DICT keys never match (SQL semantics)."""
    var b_a_idx: List[Int] = [0]
    var b_b_idx: List[Int] = [0]
    var b_a_nulls: List[Bool] = [False]
    var b_b_nulls: List[Bool] = [False]
    var dict_a: List[String] = ["x"]
    var dict_b: List[String] = ["y"]
    var b = _make_2col_dict_dict_with_nulls(
        "a", "b",
        b_a_idx, b_a_nulls, dict_a,
        b_b_idx, b_b_nulls, dict_b,
    )

    var p_a_idx: List[Int] = [0, 0]
    var p_b_idx: List[Int] = [0, 0]
    var p_a_nulls: List[Bool] = [True, False]    # row 0: NULL key
    var p_b_nulls: List[Bool] = [False, False]
    var p = _make_2col_dict_dict_with_nulls(
        "a", "b",
        p_a_idx, p_a_nulls, dict_a,
        p_b_idx, p_b_nulls, dict_b,
    )

    var bk = List[String]()
    bk.append("a")
    bk.append("b")
    var pk = List[String]()
    pk.append("a")
    pk.append("b")

    var bks = extract_join_key_columns_serial(b, bk)
    var pks = extract_join_key_columns_serial(p, pk)
    var bm_pm = _direct_inner_probe(bks^, pks^)

    assert_equal(len(bm_pm[0]), 1)
    assert_equal(bm_pm[1][0], 1)


def test_dict_null_keys_anti_emits() raises:
    """NULL DICT keys emit from ANTI (no match -> kept)."""
    var b_a_idx: List[Int] = [0]
    var b_b_idx: List[Int] = [0]
    var b_a_nulls: List[Bool] = [False]
    var b_b_nulls: List[Bool] = [False]
    var dict_a: List[String] = ["x"]
    var dict_b: List[String] = ["y"]
    var b = _make_2col_dict_dict_with_nulls(
        "a", "b",
        b_a_idx, b_a_nulls, dict_a,
        b_b_idx, b_b_nulls, dict_b,
    )

    var p_a_idx: List[Int] = [0, 0]
    var p_b_idx: List[Int] = [0, 0]
    var p_a_nulls: List[Bool] = [True, False]
    var p_b_nulls: List[Bool] = [False, False]
    var p = _make_2col_dict_dict_with_nulls(
        "a", "b",
        p_a_idx, p_a_nulls, dict_a,
        p_b_idx, p_b_nulls, dict_b,
    )

    var bk = List[String]()
    bk.append("a")
    bk.append("b")
    var pk = List[String]()
    pk.append("a")
    pk.append("b")

    var bks = extract_join_key_columns_serial(b, bk)
    var pks = extract_join_key_columns_serial(p, pk)
    var builder = MultiKeyHashJoinBuilder.build(bks^)
    var anti = multi_key_probe_anti(builder, pks)

    assert_equal(len(anti), 1)
    assert_equal(anti[0], 0)


def test_dict_empty_dictionary() raises:
    """DICT with empty dictionary on build side: probe yields no matches."""
    var b_a_idx: List[Int] = []
    var b_b_idx: List[Int] = []
    var b_dict_a: List[String] = ["a"]  # dict needs at least 1 row to define
    var b_dict_b: List[String] = ["b"]
    var b = _make_2col_dict_dict(
        "a", "b",
        b_a_idx, b_dict_a,
        b_b_idx, b_dict_b,
    )

    var p_a_idx: List[Int] = [0]
    var p_b_idx: List[Int] = [0]
    var p = _make_2col_dict_dict(
        "a", "b",
        p_a_idx, b_dict_a,
        p_b_idx, b_dict_b,
    )

    var bk = List[String]()
    bk.append("a")
    bk.append("b")
    var pk = List[String]()
    pk.append("a")
    pk.append("b")

    var bks = extract_join_key_columns_serial(b, bk)
    var pks = extract_join_key_columns_serial(p, pk)
    var bm_pm = _direct_inner_probe(bks^, pks^)
    assert_equal(len(bm_pm[0]), 0)


def test_dict_int64_int64_regression_after_c3() raises:
    """INT64 + INT64 keys carry no DICT side channel."""
    var b_a: List[Int] = [1, 2, 3]
    var b_b: List[Int] = [10, 20, 30]
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.INT64, False))
    var bldr = RecordBatchBuilder()
    bldr.add_column(_make_int64_col("a", b_a))
    bldr.add_column(_make_int64_col("b", b_b))
    var b = bldr.build(sb.build()^)

    var p_a: List[Int] = [1, 2, 3]
    var p_b: List[Int] = [10, 20, 99]
    var sb2 = SchemaBuilder()
    sb2.add_field(Field("a", ArrowType.INT64, False))
    sb2.add_field(Field("b", ArrowType.INT64, False))
    var bldr2 = RecordBatchBuilder()
    bldr2.add_column(_make_int64_col("a", p_a))
    bldr2.add_column(_make_int64_col("b", p_b))
    var p = bldr2.build(sb2.build()^)

    var bk = List[String]()
    bk.append("a")
    bk.append("b")
    var pk = List[String]()
    pk.append("a")
    pk.append("b")

    var bks = extract_join_key_columns_serial(b, bk)
    var pks = extract_join_key_columns_serial(p, pk)
    var bm_pm = _direct_inner_probe(bks^, pks^)

    assert_equal(len(bm_pm[0]), 2)


def test_dict_string_string_regression_after_c3() raises:
    """STRING + STRING keys carry no DICT side channel."""
    var b_a: List[String] = ["x", "y"]
    var b_b: List[String] = ["a", "b"]
    var b = _make_2col_string_string_for_dict_compare("a", "b", b_a, b_b)

    var p_a: List[String] = ["x", "y", "z"]
    var p_b: List[String] = ["a", "b", "c"]
    var p = _make_2col_string_string_for_dict_compare("a", "b", p_a, p_b)

    var bk = List[String]()
    bk.append("a")
    bk.append("b")
    var pk = List[String]()
    pk.append("a")
    pk.append("b")

    var bks = extract_join_key_columns_serial(b, bk)
    var pks = extract_join_key_columns_serial(p, pk)
    var bm_pm = _direct_inner_probe(bks^, pks^)

    assert_equal(len(bm_pm[0]), 2)


def main() raises:
    var suite = TestSuite()
    suite.test[test_extract_helper_accepts_dict_dtype]()
    suite.test[test_dict_dict_inner_same_dict]()
    suite.test[test_dict_dict_inner_cross_dict]()
    suite.test[test_dict_dict_inner_same_dict_matches_cross_dict]()
    suite.test[test_dict_int64_mixed_inner]()
    suite.test[test_dict_string_mixed_inner]()
    suite.test[test_dict_left_emits_unmatched]()
    suite.test[test_dict_semi_returns_matched_probes]()
    suite.test[test_dict_anti_returns_unmatched_probes]()
    suite.test[test_dict_null_keys_no_match_inner]()
    suite.test[test_dict_null_keys_anti_emits]()
    suite.test[test_dict_empty_dictionary]()
    suite.test[test_dict_int64_int64_regression_after_c3]()
    suite.test[test_dict_string_string_regression_after_c3]()
    suite^.run()
