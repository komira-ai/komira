# =============================================================================
# Field parameter round-trip tests
# =============================================================================
#
# Verifies the Field/Schema plumbing for parameter-bearing Arrow types:
#
#   1. Field.format_string() emits the Arrow-spec-correct parameterized
#      format string from Field's parameter slots (decimal P/S, timestamp
#      tz, union type-ids, dict index type).
#   2. The param-extractor helpers (`extract_decimal_params`,
#      `extract_timestamp_timezone`, `extract_union_type_ids`) recover the
#      exact parameters that were emitted.
#   3. Round-trip property: emit -> parse + extract -> reconstruct ->
#      emit byte-identical.
#   4. SchemaBuilder/Schema plumb the parameter slots through Field
#      construction without loss.
#   5. Schema.row_width_bytes() returns the correct byte width for every
#      time / duration / interval / decimal / union type slot.
#
# Plumbing only: no array variants, no C-Data codepath.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType, decimal_format_string, decimal256_format_string, timestamp_format_string, union_format_string, parse_format_string, extract_decimal_params, extract_timestamp_timezone, extract_union_type_ids
from komira_arrow.schema import Field, Schema, SchemaBuilder


# =============================================================================
# Field.format_string() — Decimal128 / Decimal256
# =============================================================================


def test_field_format_string_decimal128() raises:
    """Field.decimal128(18, 6).format_string() == 'd:18,6'."""
    var f = Field.decimal128("price", 18, 6, True)
    assert_equal(f.format_string(), "d:18,6")
    # Inverse: parse + extract recovers the parameters.
    assert_true(parse_format_string(f.format_string()) == ArrowType.DECIMAL128)
    var ps = extract_decimal_params(f.format_string())
    assert_equal(ps[0], 18)
    assert_equal(ps[1], 6)
    assert_equal(ps[2], 128)


def test_field_format_string_decimal256() raises:
    """Field.decimal256(38, 2).format_string() == 'd:38,2,256'."""
    var f = Field.decimal256("price", 38, 2, True)
    assert_equal(f.format_string(), "d:38,2,256")
    assert_true(parse_format_string(f.format_string()) == ArrowType.DECIMAL256)
    var ps = extract_decimal_params(f.format_string())
    assert_equal(ps[0], 38)
    assert_equal(ps[1], 2)
    assert_equal(ps[2], 256)


def test_field_format_string_decimal_round_trip_byte_identical() raises:
    """Round-trip property: emit -> parse + extract -> reconstruct ->
    emit byte-identical."""
    var f0 = Field.decimal128("a", 24, 4, True)
    var s0 = f0.format_string()
    # Reconstruct from parsed params.
    var t = parse_format_string(s0)
    var ps = extract_decimal_params(s0)
    var f1 = Field.decimal128("a", ps[0], ps[1], True)
    assert_equal(f0.format_string(), f1.format_string())
    assert_true(t == ArrowType.DECIMAL128)


def test_field_format_string_decimal256_round_trip_byte_identical() raises:
    var f0 = Field.decimal256("a", 60, 10, True)
    var s0 = f0.format_string()
    var t = parse_format_string(s0)
    var ps = extract_decimal_params(s0)
    var f1 = Field.decimal256("a", ps[0], ps[1], True)
    assert_equal(f0.format_string(), f1.format_string())
    assert_true(t == ArrowType.DECIMAL256)
    assert_equal(ps[2], 256)


# =============================================================================
# Field.format_string() — Timestamp with tz
# =============================================================================


def test_field_format_string_timestamp_with_tz_us() raises:
    var f = Field.timestamp("event_ts", ArrowType.TIMESTAMP_US, "UTC", True)
    assert_equal(f.format_string(), "tsu:UTC")
    assert_equal(f.timezone(), "UTC")
    assert_true(parse_format_string(f.format_string()) == ArrowType.TIMESTAMP_US)
    assert_equal(extract_timestamp_timezone(f.format_string()), "UTC")


def test_field_format_string_timestamp_with_tz_ns() raises:
    var f = Field.timestamp(
        "event_ts", ArrowType.TIMESTAMP_NS, "America/Los_Angeles", True
    )
    assert_equal(f.format_string(), "tsn:America/Los_Angeles")
    assert_true(parse_format_string(f.format_string()) == ArrowType.TIMESTAMP_NS)
    assert_equal(
        extract_timestamp_timezone(f.format_string()), "America/Los_Angeles"
    )


def test_field_format_string_timestamp_no_tz() raises:
    """Empty timezone serializes as 'ts<unit>:' with a trailing colon."""
    var f = Field.timestamp("naive", ArrowType.TIMESTAMP_MS, "", True)
    assert_equal(f.format_string(), "tsm:")
    assert_equal(f.timezone(), "")
    assert_equal(extract_timestamp_timezone(f.format_string()), "")


def test_field_format_string_timestamp_round_trip_byte_identical() raises:
    """Round-trip a tz-aware timestamp field via format string + helpers."""
    var f0 = Field.timestamp("ts", ArrowType.TIMESTAMP_US, "UTC", True)
    var s0 = f0.format_string()
    var t = parse_format_string(s0)
    var tz = extract_timestamp_timezone(s0)
    var f1 = Field.timestamp("ts", t, tz, True)
    assert_equal(f0.format_string(), f1.format_string())


def test_field_format_string_timestamp_legacy_emits_tsu() raises:
    """ArrowType.TIMESTAMP (legacy alias) emits 'tsu:' same as TIMESTAMP_US;
    parse_format_string returns TIMESTAMP_US (id 24). Documented behavior."""
    var f = Field.timestamp("ts", ArrowType.TIMESTAMP, "UTC", True)
    assert_equal(f.format_string(), "tsu:UTC")
    # The parser disambiguates legacy 'tsu:' to TIMESTAMP_US (id 24).
    # Round-trip lands on TIMESTAMP_US, NOT the legacy TIMESTAMP slot.
    assert_true(parse_format_string(f.format_string()) == ArrowType.TIMESTAMP_US)


# =============================================================================
# Field.format_string() — Union sparse / dense
# =============================================================================


def test_field_format_string_union_sparse() raises:
    var ids: List[Int] = [0, 1, 2]
    var f = Field.union("payload", ArrowType.UNION_SPARSE, ids, True)
    assert_equal(f.format_string(), "+us:0,1,2")
    assert_true(parse_format_string(f.format_string()) == ArrowType.UNION_SPARSE)
    var extracted = extract_union_type_ids(f.format_string())
    assert_equal(len(extracted), 3)
    assert_equal(extracted[0], 0)
    assert_equal(extracted[1], 1)
    assert_equal(extracted[2], 2)


def test_field_format_string_union_dense() raises:
    var ids: List[Int] = [5, 7]
    var f = Field.union("payload", ArrowType.UNION_DENSE, ids, True)
    assert_equal(f.format_string(), "+ud:5,7")
    assert_true(parse_format_string(f.format_string()) == ArrowType.UNION_DENSE)
    var extracted = extract_union_type_ids(f.format_string())
    assert_equal(len(extracted), 2)
    assert_equal(extracted[0], 5)
    assert_equal(extracted[1], 7)


def test_field_format_string_union_round_trip_byte_identical() raises:
    var ids: List[Int] = [0, 3, 7, 12]
    var f0 = Field.union("u", ArrowType.UNION_SPARSE, ids, True)
    var s0 = f0.format_string()
    var t = parse_format_string(s0)
    var parsed_ids = extract_union_type_ids(s0)
    var f1 = Field.union("u", t, parsed_ids, True)
    assert_equal(f0.format_string(), f1.format_string())


# =============================================================================
# Field.format_string() — Dictionary
# =============================================================================


def test_field_format_string_dictionary_default_index() raises:
    """DICTIONARY field with default INT32 index serializes the index
    format string at the parent level (per Arrow C Data Interface spec)."""
    var f = Field.dictionary("cat", ArrowType.INT32, True)
    # The parent emits the INDEX format string; value type lives on
    # the (separately-attached) dictionary schema.
    assert_equal(f.format_string(), "i")
    assert_true(f.dict_index_type() == ArrowType.INT32)


def test_field_format_string_dictionary_int8_index() raises:
    """DICTIONARY with INT8 index emits 'c' (the INT8 format string)."""
    var f = Field.dictionary("low_card", ArrowType.INT8, True)
    assert_equal(f.format_string(), "c")
    assert_true(f.dict_index_type() == ArrowType.INT8)


def test_field_dictionary_validates_index_type() raises:
    """Field.dictionary() rejects non-integer index types per Arrow spec."""
    var raised = False
    try:
        _ = Field.dictionary("bad", ArrowType.FLOAT64, True)
    except:
        raised = True
    assert_true(raised)


# =============================================================================
# Schema plumbing — params survive SchemaBuilder.build -> Schema -> field_at
# =============================================================================


def test_schema_plumbs_timestamp_tz() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field.timestamp("ts", ArrowType.TIMESTAMP_NS, "UTC", True))
    sb.add_field(Field("id", ArrowType.INT64, False))
    var schema = sb.build()
    assert_equal(schema.field_tz(0), "UTC")
    assert_equal(schema.field_tz(1), "")
    var f0 = schema.field_at(0)
    assert_equal(f0.timezone(), "UTC")
    assert_true(f0.arrow_type == ArrowType.TIMESTAMP_NS)


def test_schema_plumbs_decimal256_precision_scale() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field.decimal256("amount", 50, 18, True))
    var schema = sb.build()
    assert_equal(schema.field_decimal_precision(0), 50)
    assert_equal(schema.field_decimal_scale(0), 18)
    var f0 = schema.field_at(0)
    assert_equal(f0.decimal_precision, 50)
    assert_equal(f0.decimal_scale, 18)
    assert_true(f0.arrow_type == ArrowType.DECIMAL256)


def test_schema_plumbs_dict_index_type() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field.dictionary("cat", ArrowType.INT16, True))
    var schema = sb.build()
    assert_true(schema.field_dict_index_type(0) == ArrowType.INT16)
    var f0 = schema.field_at(0)
    assert_true(f0.dict_index_type() == ArrowType.INT16)


def test_schema_plumbs_union_type_ids() raises:
    var sb = SchemaBuilder()
    var ids: List[Int] = [0, 1, 2, 3]
    sb.add_field(Field.union("u", ArrowType.UNION_DENSE, ids, True))
    var schema = sb.build()
    var ids_out = schema.field_union_type_ids(0)
    assert_equal(len(ids_out), 4)
    assert_equal(ids_out[0], 0)
    assert_equal(ids_out[1], 1)
    assert_equal(ids_out[2], 2)
    assert_equal(ids_out[3], 3)
    var f0 = schema.field_at(0)
    assert_true(f0.arrow_type == ArrowType.UNION_DENSE)
    var f0_ids = f0.union_type_ids()
    assert_equal(len(f0_ids), 4)


def test_schema_backward_compat_default_params() raises:
    """A field constructed via the plain ctor has empty tz, INT32 dict index,
    and empty union type-ids -- the defaults every parameter slot starts at."""
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT32, True))
    var schema = sb.build()
    assert_equal(schema.field_tz(0), "")
    assert_true(schema.field_dict_index_type(0) == ArrowType.INT32)
    assert_equal(len(schema.field_union_type_ids(0)), 0)


# =============================================================================
# Schema.row_width_bytes() — time / duration / interval / decimal / union arms
# =============================================================================


def test_row_width_decimal256_is_32() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field.decimal256("x", 38, 2, True))
    assert_equal(sb.build().row_width_bytes(), 32)


def test_row_width_time32_is_4() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.TIME32_S, True))
    sb.add_field(Field("b", ArrowType.TIME32_MS, True))
    # Two TIME32 columns -> 8 bytes total.
    assert_equal(sb.build().row_width_bytes(), 8)


def test_row_width_time64_is_8() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.TIME64_US, True))
    sb.add_field(Field("b", ArrowType.TIME64_NS, True))
    assert_equal(sb.build().row_width_bytes(), 16)


def test_row_width_duration_is_8() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.DURATION_S, True))
    sb.add_field(Field("b", ArrowType.DURATION_MS, True))
    sb.add_field(Field("c", ArrowType.DURATION_US, True))
    sb.add_field(Field("d", ArrowType.DURATION_NS, True))
    # Four Duration columns × 8 bytes = 32 bytes.
    assert_equal(sb.build().row_width_bytes(), 32)


def test_row_width_interval_year_month_is_4() raises:
    """IntervalYearMonth is int32 per Arrow spec (4 bytes)."""
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INTERVAL_YEAR_MONTH, True))
    assert_equal(sb.build().row_width_bytes(), 4)


def test_row_width_interval_day_time_is_8() raises:
    """IntervalDayTime is two int32s = 8 bytes per Arrow spec."""
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INTERVAL_DAY_TIME, True))
    assert_equal(sb.build().row_width_bytes(), 8)


def test_row_width_interval_month_day_nano_is_16() raises:
    """IntervalMonthDayNano = int32 + int32 + int64 = 16 bytes."""
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INTERVAL_MONTH_DAY_NANO, True))
    assert_equal(sb.build().row_width_bytes(), 16)


def test_row_width_union_is_8_sentinel() raises:
    """Union row width is variable; we return 8 (the prior fallthrough)."""
    var sb = SchemaBuilder()
    var ids: List[Int] = [0, 1]
    sb.add_field(Field.union("u", ArrowType.UNION_SPARSE, ids, True))
    assert_equal(sb.build().row_width_bytes(), 8)


def test_row_width_mixed_phase_a_types() raises:
    """Regression: a mixed row of classic + time/decimal/interval types sums correctly."""
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))           # 8
    sb.add_field(Field("b", ArrowType.TIME32_MS, True))       # 4
    sb.add_field(Field("c", ArrowType.DECIMAL128, True))      # 16
    sb.add_field(Field.decimal256("d", 38, 2, True))          # 32
    sb.add_field(Field("e", ArrowType.INTERVAL_MONTH_DAY_NANO, True))  # 16
    assert_equal(sb.build().row_width_bytes(), 8 + 4 + 16 + 32 + 16)


# =============================================================================
# Param extractor — parser surface
# =============================================================================


def test_extract_decimal_params_d128() raises:
    var r = extract_decimal_params("d:18,6")
    assert_equal(r[0], 18)
    assert_equal(r[1], 6)
    assert_equal(r[2], 128)


def test_extract_decimal_params_d256() raises:
    var r = extract_decimal_params("d:38,2,256")
    assert_equal(r[0], 38)
    assert_equal(r[1], 2)
    assert_equal(r[2], 256)


def test_extract_decimal_params_malformed_returns_zeros() raises:
    var r = extract_decimal_params("foo")
    assert_equal(r[0], 0)
    assert_equal(r[1], 0)
    assert_equal(r[2], 0)
    var r2 = extract_decimal_params("d:")
    assert_equal(r2[0], 0)


def test_extract_timestamp_timezone_with_tz() raises:
    assert_equal(extract_timestamp_timezone("tsu:UTC"), "UTC")
    assert_equal(extract_timestamp_timezone("tsn:America/New_York"), "America/New_York")
    assert_equal(extract_timestamp_timezone("tss:"), "")


def test_extract_timestamp_timezone_non_timestamp_returns_empty() raises:
    assert_equal(extract_timestamp_timezone(""), "")
    assert_equal(extract_timestamp_timezone("foo"), "")
    assert_equal(extract_timestamp_timezone("i"), "")


def test_extract_union_type_ids_sparse() raises:
    var ids = extract_union_type_ids("+us:0,1,2")
    assert_equal(len(ids), 3)
    assert_equal(ids[0], 0)
    assert_equal(ids[1], 1)
    assert_equal(ids[2], 2)


def test_extract_union_type_ids_dense() raises:
    var ids = extract_union_type_ids("+ud:5,7,11")
    assert_equal(len(ids), 3)
    assert_equal(ids[0], 5)
    assert_equal(ids[1], 7)
    assert_equal(ids[2], 11)


def test_extract_union_type_ids_empty() raises:
    """Empty union type-id list (rare but spec-legal): '+us:' -> []."""
    var ids = extract_union_type_ids("+us:")
    assert_equal(len(ids), 0)


def test_extract_union_type_ids_malformed() raises:
    assert_equal(len(extract_union_type_ids("foo")), 0)
    assert_equal(len(extract_union_type_ids("+us")), 0)
    assert_equal(len(extract_union_type_ids("+u")), 0)


# =============================================================================
# `Field.list_of` and its losslessness gate
# =============================================================================
#
# WHY THESE LIVE IN *THIS* FILE. The whole question `list_item_type_is_lossless`
# answers is "does this item type need a Field PARAMETER SLOT that the three
# flat child lists do not carry" — and the parameter slots, and the proof that
# they round-trip, are exactly what the rest of this file is about. A test of
# the gate placed anywhere else would be a test of a list helper; placed here
# it sits next to the `decimal128` / `timestamp` / union cases that are the
# REASON the gate says no.
# =============================================================================


def test_list_of_builds_the_declared_item_type() raises:
    """`Field.list_of(T)` is LIST with exactly one child "item" of type T.

    The generalization `list_of_string` had hardcoded. Graded over four
    unrelated item families so a body that ignored `item_type` and emitted a
    fixed type cannot pass: an integer, a float, a string and a date.
    """
    var fi = Field.list_of("ints", ArrowType.INT64, True)
    assert_true(fi.arrow_type == ArrowType.LIST)
    assert_equal(fi.num_children(), 1)
    assert_equal(fi.child_name(0), "item")
    assert_true(fi.child_arrow_type(0) == ArrowType.INT64)

    var ff = Field.list_of("floats", ArrowType.FLOAT64, True)
    assert_true(ff.child_arrow_type(0) == ArrowType.FLOAT64)

    var fs = Field.list_of("strs", ArrowType.STRING, True)
    assert_true(fs.child_arrow_type(0) == ArrowType.STRING)

    var fd = Field.list_of("dates", ArrowType.DATE32, True)
    assert_true(fd.child_arrow_type(0) == ArrowType.DATE32)


def test_list_of_threads_both_nullability_flags() raises:
    """LIST nullability and ITEM nullability are two independent flags.

    They are adjacent Bool parameters, so a body that passed the wrong one
    through would still produce a plausible Field. Pinned in the
    (False, True) and (True, False) corners, where swapping them shows.
    """
    var a = Field.list_of("a", ArrowType.INT64, False, item_nullable=True)
    assert_false(a.nullable)
    assert_true(a.child_nullable(0))

    var b = Field.list_of("b", ArrowType.INT64, True, item_nullable=False)
    assert_true(b.nullable)
    assert_false(b.child_nullable(0))


def test_list_of_string_is_the_same_field_as_before() raises:
    """`list_of_string` now forwards to `list_of`; it must not have moved.

    This is the regression guard on the refactor itself — three `expr_walk`
    arms (`regexp_match`, `regexp_split_to_array`, `regexp_extract_all`) and
    the plan-wire golden-bytes test depend on this exact shape.
    """
    var f = Field.list_of_string("m", True, item_nullable=False)
    assert_true(f.arrow_type == ArrowType.LIST)
    assert_equal(f.name, "m")
    assert_true(f.nullable)
    assert_equal(f.num_children(), 1)
    assert_equal(f.child_name(0), "item")
    assert_true(f.child_arrow_type(0) == ArrowType.STRING)
    assert_false(f.child_nullable(0))


def test_list_item_type_lossless_admits_the_unparameterized_families() raises:
    """Every item type fully described by `(name, type_id, nullable)`."""
    assert_true(Field.list_item_type_is_lossless(ArrowType.BOOL))
    assert_true(Field.list_item_type_is_lossless(ArrowType.INT32))
    assert_true(Field.list_item_type_is_lossless(ArrowType.INT64))
    assert_true(Field.list_item_type_is_lossless(ArrowType.UINT8))
    assert_true(Field.list_item_type_is_lossless(ArrowType.FLOAT64))
    assert_true(Field.list_item_type_is_lossless(ArrowType.STRING))
    assert_true(Field.list_item_type_is_lossless(ArrowType.LARGE_STRING))
    assert_true(Field.list_item_type_is_lossless(ArrowType.BINARY))
    assert_true(Field.list_item_type_is_lossless(ArrowType.DATE32))
    assert_true(Field.list_item_type_is_lossless(ArrowType.DATE64))
    assert_true(Field.list_item_type_is_lossless(ArrowType.TIME64_US))
    assert_true(Field.list_item_type_is_lossless(ArrowType.DURATION_MS))
    assert_true(Field.list_item_type_is_lossless(ArrowType.INTERVAL_DAY_TIME))


def test_list_item_type_lossless_refuses_every_parameter_bearing_type() raises:
    """⭐ THE LOAD-BEARING HALF. Each of these needs a Field slot the three
    flat child lists do not have, so `Field.list_of` would emit a
    plausible-looking Field carrying a WRONG type.

    Proven NOT vacuous in the same breath: for DECIMAL128 and TIMESTAMP the
    loss is CONSTRUCTED below, so these are not merely "the gate says no" —
    they are "the gate says no AND here is the wrong Field it is stopping".
    """
    # Parameter-bearing scalars.
    assert_false(Field.list_item_type_is_lossless(ArrowType.DECIMAL128))
    assert_false(Field.list_item_type_is_lossless(ArrowType.DECIMAL256))
    assert_false(Field.list_item_type_is_lossless(ArrowType.TIMESTAMP))
    assert_false(Field.list_item_type_is_lossless(ArrowType.TIMESTAMP_S))
    assert_false(Field.list_item_type_is_lossless(ArrowType.TIMESTAMP_NS))
    assert_false(Field.list_item_type_is_lossless(ArrowType.DICTIONARY))
    assert_false(Field.list_item_type_is_lossless(ArrowType.UNION_SPARSE))
    assert_false(Field.list_item_type_is_lossless(ArrowType.UNION_DENSE))
    assert_false(Field.list_item_type_is_lossless(ArrowType.FIXED_SIZE_BINARY))
    # Nested: needs children of its own.
    assert_false(Field.list_item_type_is_lossless(ArrowType.LIST))
    assert_false(Field.list_item_type_is_lossless(ArrowType.LARGE_LIST))
    assert_false(Field.list_item_type_is_lossless(ArrowType.FIXED_SIZE_LIST))
    assert_false(Field.list_item_type_is_lossless(ArrowType.STRUCT))
    assert_false(Field.list_item_type_is_lossless(ArrowType.MAP))


def test_the_loss_the_gate_refuses_is_real_not_hypothetical() raises:
    """⛔ CONSTRUCT the wrong Field the gate exists to stop.

    Without this cell the two gate tests above are just a table restating
    itself: they would pass identically if `Field.list_of` DID carry decimal
    parameters and the gate were merely over-conservative. Here the loss is
    MEASURED — a DECIMAL128(18,6) item comes back as (0, 0), and a
    tz-bearing TIMESTAMP item comes back indistinguishable from a naive one
    because the child lists carry only the type id.
    """
    # A standalone DECIMAL128 Field carries (18, 6) ...
    var scalar_dec = Field.decimal128("price", 18, 6, True)
    assert_equal(scalar_dec.decimal_precision, 18)
    assert_equal(scalar_dec.decimal_scale, 6)

    # ... but as a LIST ITEM the parameters have nowhere to go.
    var list_dec = Field.list_of("prices", ArrowType.DECIMAL128, True)
    assert_true(list_dec.child_arrow_type(0) == ArrowType.DECIMAL128)
    # The child is describable ONLY by its type id — no p/s survived.
    assert_equal(list_dec.num_children(), 1)
    assert_false(Field.list_item_type_is_lossless(ArrowType.DECIMAL128))

    # Same shape for tz: a tz-bearing timestamp and a naive one produce the
    # SAME list child, which is why the family is refused wholesale.
    var tz_list = Field.list_of("ts_tz", ArrowType.TIMESTAMP_US, True)
    var naive_list = Field.list_of("ts_naive", ArrowType.TIMESTAMP_US, True)
    assert_true(
        tz_list.child_arrow_type(0) == naive_list.child_arrow_type(0)
    )
    assert_false(Field.list_item_type_is_lossless(ArrowType.TIMESTAMP_US))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
