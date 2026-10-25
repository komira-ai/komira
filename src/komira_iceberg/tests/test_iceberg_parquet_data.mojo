# =============================================================================
# test_iceberg_parquet_data.mojo — the Parquet data-file leg.
# =============================================================================
#
# What each test proves (and the defect it catches):
#   1. Every column type, with nulls, round-trips through a Parquet file in
#      memory: the typed cell comes back equal, a null comes back null (not 0).
#   2. Rows come back in written order: the position-delete predicate masks by
#      file-absolute row ordinal, so a reordering decoder silently deletes the
#      wrong rows.
#   3. The writer opens no file: the bytes it returns are a Parquet file
#      (PAR1 magic at both ends), and building twice gives two independent
#      byte strings (no shared staging path).
#   4. A file written under an older, narrower schema reads with the added
#      trailing columns NULL; a wider file than the schema is refused.
#   5. Mistyped cells, a null in a required column, a wrong-arity row, and
#      bytes that are not a Parquet file are refused, not coerced or misread.
# =============================================================================

from std.testing import assert_true, assert_equal, assert_false, assert_raises

from komira_iceberg import (
    ICE_T_BOOLEAN,
    ICE_T_INT,
    ICE_T_LONG,
    ICE_T_FLOAT,
    ICE_T_DOUBLE,
    ICE_T_STRING,
    IcebergSchema,
    RowCell,
    make_boolean_cell,
    make_int_cell,
    make_long_cell,
    make_float_cell,
    make_double_cell,
    make_string_cell,
    make_null_cell,
    rows_equal,
    col_types_of,
    build_parquet_data_file,
    read_parquet_data_file,
    check_row_group_range,
)


def _all_types_schema() -> IcebergSchema:
    var s = IcebergSchema(0)
    s.add(String("id"), ICE_T_LONG, required=True)
    s.add(String("name"), ICE_T_STRING)
    s.add(String("score"), ICE_T_DOUBLE)
    s.add(String("flag"), ICE_T_BOOLEAN)
    s.add(String("n"), ICE_T_INT)
    s.add(String("f"), ICE_T_FLOAT)
    return s^


def _row(
    id: Int64, var name: String, score: Float64, flag: Bool, n: Int32, f: Float32
) -> List[RowCell]:
    var r = List[RowCell]()
    r.append(make_long_cell(id))
    r.append(make_string_cell(name^))
    r.append(make_double_cell(score))
    r.append(make_boolean_cell(flag))
    r.append(make_int_cell(n))
    r.append(make_float_cell(f))
    return r^


def _null_row(id: Int64) -> List[RowCell]:
    var r = List[RowCell]()
    r.append(make_long_cell(id))
    r.append(make_null_cell(ICE_T_STRING))
    r.append(make_null_cell(ICE_T_DOUBLE))
    r.append(make_null_cell(ICE_T_BOOLEAN))
    r.append(make_null_cell(ICE_T_INT))
    r.append(make_null_cell(ICE_T_FLOAT))
    return r^


def test_every_type_and_null_round_trips() raises:
    var schema = _all_types_schema()
    var rows = List[List[RowCell]]()
    rows.append(_row(1, String("alpha"), 1.5, True, Int32(-7), Float32(2.25)))
    rows.append(_null_row(2))
    rows.append(_row(3, String("café 日本"), -0.5, False, Int32(0), Float32(-1.0)))
    rows.append(_row(-4, String(""), 1e300, True, Int32(2147483647), Float32(0.5)))
    var bytes = build_parquet_data_file(schema, rows)
    var back = read_parquet_data_file(bytes, col_types_of(schema))
    assert_equal(len(back), 4)
    for i in range(4):
        assert_true(rows_equal(rows[i], back[i]), "row " + String(i) + " differs")
    # Nulls are real nulls, not zero values.
    for c in range(1, 6):
        assert_true(back[1][c].is_null(), "column " + String(c) + " lost its null")
    assert_false(back[2][1].is_null())
    assert_equal(back[2][1].as_string(), String("café 日本"))


def test_rows_come_back_in_written_order() raises:
    var schema = IcebergSchema(0)
    schema.add(String("id"), ICE_T_LONG, required=True)
    var rows = List[List[RowCell]]()
    for i in range(1500):
        var r = List[RowCell]()
        r.append(make_long_cell(Int64((i * 7919) % 1500)))
        rows.append(r^)
    var back = read_parquet_data_file(build_parquet_data_file(schema, rows), col_types_of(schema))
    assert_equal(len(back), 1500)
    for i in range(1500):
        assert_equal(back[i][0].as_long(), Int64((i * 7919) % 1500))


def test_the_bytes_are_a_parquet_file_and_independent() raises:
    var schema = IcebergSchema(0)
    schema.add(String("id"), ICE_T_LONG, required=True)
    var a = List[List[RowCell]]()
    var ra = List[RowCell]()
    ra.append(make_long_cell(Int64(1)))
    a.append(ra^)
    var b = List[List[RowCell]]()
    var rb = List[RowCell]()
    rb.append(make_long_cell(Int64(2)))
    b.append(rb^)
    var bytes_a = build_parquet_data_file(schema, a)
    var bytes_b = build_parquet_data_file(schema, b)
    for bytes in [bytes_a.copy(), bytes_b.copy()]:
        var n = len(bytes)
        assert_equal(bytes[0], UInt8(ord("P")))
        assert_equal(bytes[3], UInt8(ord("1")))
        assert_equal(bytes[n - 4], UInt8(ord("P")))
        assert_equal(bytes[n - 1], UInt8(ord("1")))
    # Reading each back gives its own row: no staging file is shared.
    var back_a = read_parquet_data_file(bytes_a, col_types_of(schema))
    var back_b = read_parquet_data_file(bytes_b, col_types_of(schema))
    assert_equal(back_a[0][0].as_long(), Int64(1))
    assert_equal(back_b[0][0].as_long(), Int64(2))


def test_a_narrower_file_reads_with_added_columns_null() raises:
    var old = IcebergSchema(0)
    old.add(String("id"), ICE_T_LONG, required=True)
    old.add(String("name"), ICE_T_STRING)
    var rows = List[List[RowCell]]()
    var r = List[RowCell]()
    r.append(make_long_cell(Int64(9)))
    r.append(make_string_cell(String("x")))
    rows.append(r^)
    var bytes = build_parquet_data_file(old, rows)
    # The table later gained a column: read the old file under the new schema.
    var evolved = IcebergSchema(1)
    evolved.add(String("id"), ICE_T_LONG, required=True)
    evolved.add(String("name"), ICE_T_STRING)
    evolved.add(String("added"), ICE_T_DOUBLE)
    var back = read_parquet_data_file(bytes, col_types_of(evolved))
    assert_equal(len(back), 1)
    assert_equal(len(back[0]), 3)
    assert_equal(back[0][0].as_long(), Int64(9))
    assert_equal(back[0][1].as_string(), String("x"))
    assert_true(back[0][2].is_null())
    # A file wider than the schema is refused (a column would be dropped).
    with assert_raises():
        _ = read_parquet_data_file(bytes, col_types_of(_one_column()))


def _one_column() -> IcebergSchema:
    var s = IcebergSchema(0)
    s.add(String("id"), ICE_T_LONG, required=True)
    return s^


def test_bad_input_is_refused() raises:
    var schema = _all_types_schema()
    # A STRING cell for the LONG id column would coerce to 0: refused.
    var mistyped = List[List[RowCell]]()
    var m = _null_row(1)
    m[0] = make_string_cell(String("12345678901234567890"))
    mistyped.append(m^)
    with assert_raises():
        _ = build_parquet_data_file(schema, mistyped)
    # A null in the REQUIRED id column.
    var null_key = List[List[RowCell]]()
    var k = _null_row(1)
    k[0] = make_null_cell(ICE_T_LONG)
    null_key.append(k^)
    with assert_raises():
        _ = build_parquet_data_file(schema, null_key)
    # A row with the wrong number of cells.
    var short = List[List[RowCell]]()
    var s = List[RowCell]()
    s.append(make_long_cell(Int64(1)))
    short.append(s^)
    with assert_raises():
        _ = build_parquet_data_file(schema, short)
    # Bytes that are not a Parquet file.
    var junk = List[UInt8]()
    for i in range(64):
        junk.append(UInt8(i))
    with assert_raises():
        _ = read_parquet_data_file(junk, col_types_of(schema))
    var tiny = List[UInt8]()
    tiny.append(UInt8(1))
    with assert_raises():
        _ = read_parquet_data_file(tiny, col_types_of(schema))
    # A valid magic with an impossible footer length.
    var bad_footer = List[UInt8]()
    for i in range(20):
        bad_footer.append(UInt8(0))
    bad_footer[12] = UInt8(0xFF)
    bad_footer[13] = UInt8(0xFF)
    bad_footer[14] = UInt8(0xFF)
    bad_footer[15] = UInt8(0x7F)
    bad_footer[16] = UInt8(ord("P"))
    bad_footer[17] = UInt8(ord("A"))
    bad_footer[18] = UInt8(ord("R"))
    bad_footer[19] = UInt8(ord("1"))
    with assert_raises():
        _ = read_parquet_data_file(bad_footer, col_types_of(schema))


def test_an_unmapped_type_tag_is_refused() raises:
    var schema = IcebergSchema(0)
    schema.add(String("weird"), 42)
    var rows = List[List[RowCell]]()
    with assert_raises():
        _ = build_parquet_data_file(schema, rows)


def test_the_row_group_range_check() raises:
    check_row_group_range(4, 100, 100)
    check_row_group_range(0, 0, 0)
    with assert_raises():
        check_row_group_range(-1, 10, 100)
    with assert_raises():
        check_row_group_range(50, 40, 100)
    with assert_raises():
        check_row_group_range(4, 101, 100)
    # An overflowed sum wraps below its start.
    with assert_raises():
        check_row_group_range(4611686018427387904, -9223372036854775808, 100)
    with assert_raises():
        check_row_group_range(0, 9223372036854775807, 100)


def test_a_footer_pointing_outside_the_file_is_refused() raises:
    var schema = IcebergSchema(0)
    schema.add(String("id"), ICE_T_LONG, required=True)
    var rows = List[List[RowCell]]()
    for i in range(200):
        var r = List[RowCell]()
        r.append(make_long_cell(Int64(i)))
        rows.append(r^)
    var bytes = build_parquet_data_file(schema, rows)
    var n = len(bytes)
    assert_equal(len(read_parquet_data_file(bytes, col_types_of(schema))), 200)
    # Drop 64 bytes from the middle of the data region: the footer (kept
    # whole) now names byte ranges that reach past where the data ends.
    var cut = List[UInt8]()
    for i in range(4):
        cut.append(bytes[i])
    for i in range(68, n):
        cut.append(bytes[i])
    with assert_raises():
        _ = read_parquet_data_file(cut, col_types_of(schema))


def main() raises:
    test_every_type_and_null_round_trips()
    test_rows_come_back_in_written_order()
    test_the_bytes_are_a_parquet_file_and_independent()
    test_a_narrower_file_reads_with_added_columns_null()
    test_bad_input_is_refused()
    test_an_unmapped_type_tag_is_refused()
    test_the_row_group_range_check()
    test_a_footer_pointing_outside_the_file_is_refused()
    print("test_iceberg_parquet_data: all passed")
