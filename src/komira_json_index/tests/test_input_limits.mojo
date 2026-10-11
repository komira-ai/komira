# =============================================================================
# Tests for komira_json_index/input_limits.mojo — the hostile-input ceilings.
# =============================================================================
#
# Each ceiling is checked at its boundary (the largest value it accepts and
# the smallest it refuses), at values whose high bytes are set (past 2^31 and
# 2^32), and through its message, which names the measured value and the
# limit so a caller learns what to change.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_json_index.input_limits import (
    MAX_ARROW_STRING_BYTES,
    MAX_JSON_CELLS_PER_INPUT_BYTE,
    MAX_JSON_COLUMNS,
    MAX_JSONL_LINE_BYTES,
    MAX_STRUCTURAL_INDEX_BYTES,
    check_arrow_string_bytes,
    check_json_column_count,
    check_jsonl_carry_size,
    check_structural_index_input_size,
    max_rows_for_columns,
    raise_json_cell_budget_exceeded,
)


def _size_error(n: Int) -> String:
    try:
        check_structural_index_input_size(n)
    except e:
        return String(e)
    return String("<no raise>")


def _columns_error(n: Int) -> String:
    try:
        check_json_column_count(n)
    except e:
        return String(e)
    return String("<no raise>")


def _string_bytes_error(n: Int, name: String) -> String:
    try:
        check_arrow_string_bytes(n, name)
    except e:
        return String(e)
    return String("<no raise>")


def _carry_error(carry: Int, chunk: Int, limit: Int) -> String:
    try:
        check_jsonl_carry_size(carry, chunk, limit)
    except e:
        return String(e)
    return String("<no raise>")


def _starts(s: String, prefix: String) raises:
    assert_true(s.startswith(prefix), "got: " + s)


def test_limits_have_their_documented_values() raises:
    assert_equal(MAX_STRUCTURAL_INDEX_BYTES, 4294967295)
    assert_equal(MAX_JSON_COLUMNS, 4096)
    assert_equal(MAX_JSON_CELLS_PER_INPUT_BYTE, 256)
    assert_equal(MAX_ARROW_STRING_BYTES, 2147483647)
    assert_equal(MAX_JSONL_LINE_BYTES, 268435456)


def test_structural_index_size_accepts_up_to_the_uint32_ceiling() raises:
    for n in [0, 1, 255, 65536, 2147483648, 4294967040, 4294967295]:
        assert_equal(_size_error(n), String("<no raise>"), String(n))


def test_structural_index_size_refuses_a_negative_length() raises:
    assert_equal(
        _size_error(-1),
        "JSON structural index: negative buffer length (-1); the input Span"
        " is malformed.",
    )
    _starts(_size_error(-4294967296), "JSON structural index: negative buffer length (-4294967296)")


def test_structural_index_size_refuses_past_the_uint32_ceiling() raises:
    var e = _size_error(4294967296)
    _starts(
        e,
        "JSON structural index: input buffer is 4294967296 bytes, which"
        " exceeds the 4294967295-byte (4 GiB) limit. The structural tape",
    )
    assert_true(e.endswith("(read_jsonl_streamed_to_batches)."), e)
    _starts(_size_error(9223372036854775807), "JSON structural index: input buffer is 9223372036854775807 bytes")
    _starts(_size_error(4294967551), "JSON structural index: input buffer is 4294967551 bytes")


def test_column_count_boundary() raises:
    for n in [-1, 0, 1, 4095, 4096]:
        assert_equal(_columns_error(n), String("<no raise>"), String(n))
    var e = _columns_error(4097)
    _starts(
        e,
        "JSON reader: schema declares 4097 columns, exceeding the 4096-column"
        " limit.",
    )
    assert_true(e.endswith("MAP column, not inferred into a wide schema."), e)
    _starts(_columns_error(4294971392), "JSON reader: schema declares 4294971392 columns")


def test_max_rows_for_columns() raises:
    # The budget is 256 cells per input byte, counting one byte more than
    # the input so an empty input still allows a row.
    assert_equal(max_rows_for_columns(1, 0), 256)
    assert_equal(max_rows_for_columns(1, 9), 2560)
    assert_equal(max_rows_for_columns(3, 9), 853)  # 2560 // 3, rounded down
    assert_equal(max_rows_for_columns(256, 9), 10)
    assert_equal(max_rows_for_columns(2561, 9), 0)
    assert_equal(max_rows_for_columns(4096, 1048575), 65536)
    # No column (or a nonsense count) is the whole budget, never a division.
    assert_equal(max_rows_for_columns(0, 9), 2560)
    assert_equal(max_rows_for_columns(-3, 9), 2560)


def _budget(rows: Int, cols: Int, input_bytes: Int) -> String:
    try:
        raise_json_cell_budget_exceeded(rows, cols, input_bytes)
    except e:
        return String(e)
    return String("<no raise>")


def test_cell_budget_error_names_rows_columns_cells_and_bytes() raises:
    var e = _budget(10, 3, 5)
    _starts(
        e,
        "JSON reader: materializing 10 rows x 3 columns = 30 accumulator cells"
        " from a 5-byte input, exceeding the budget of 256 cells per input"
        " byte.",
    )
    assert_true(e.endswith("(read_jsonl_streamed_to_batches)."), e)
    _starts(
        _budget(65537, 4096, 1048575),
        "JSON reader: materializing 65537 rows x 4096 columns = 268439552"
        " accumulator cells from a 1048575-byte input",
    )


def test_arrow_string_bytes_boundary() raises:
    for n in [0, 1, 2147483646, 2147483647]:
        assert_equal(_string_bytes_error(n, String("c")), String("<no raise>"), String(n))
    var e = _string_bytes_error(2147483648, String("payload"))
    _starts(
        e,
        "JSON reader: STRING column 'payload' accumulated 2147483648 bytes,"
        " exceeding the Arrow STRING limit of 2147483647 bytes (Int32"
        " offsets).",
    )
    assert_true(e.endswith("LARGE_STRING (64-bit offsets)."), e)
    _starts(
        _string_bytes_error(1095216660480, String("")),
        "JSON reader: STRING column '' accumulated 1095216660480 bytes",
    )


def test_jsonl_carry_boundary() raises:
    assert_equal(_carry_error(100, 4, 100), String("<no raise>"))
    assert_equal(_carry_error(0, 4, 0), String("<no raise>"))
    assert_equal(
        _carry_error(MAX_JSONL_LINE_BYTES, 4194304, MAX_JSONL_LINE_BYTES),
        String("<no raise>"),
    )
    var e = _carry_error(101, 4, 100)
    _starts(
        e,
        "JSONL streaming reader: a single line has reached 101 bytes without"
        " a terminating newline, exceeding the 100-byte line limit (chunk"
        " size 4 bytes).",
    )
    assert_true(e.endswith("(quadratic copy, ~2x file resident)."), e)
    _starts(
        _carry_error(268435457, 4194304, MAX_JSONL_LINE_BYTES),
        "JSONL streaming reader: a single line has reached 268435457 bytes"
        " without a terminating newline, exceeding the 268435456-byte line"
        " limit (chunk size 4194304 bytes).",
    )


def _run(name: String, f: def() raises thin -> None, mut failed: List[String]):
    """Run one case; a failure is recorded, not fatal, so a red build names
    EVERY failing case rather than only the first."""
    try:
        f()
        print("PASS", name)
    except e:
        print("FAIL", name, ":", e)
        failed.append(name)


def main() raises:
    var failed = List[String]()
    _run("test_limits_have_their_documented_values", test_limits_have_their_documented_values, failed)
    _run("test_structural_index_size_accepts_up_to_the_uint32_ceiling", test_structural_index_size_accepts_up_to_the_uint32_ceiling, failed)
    _run("test_structural_index_size_refuses_a_negative_length", test_structural_index_size_refuses_a_negative_length, failed)
    _run("test_structural_index_size_refuses_past_the_uint32_ceiling", test_structural_index_size_refuses_past_the_uint32_ceiling, failed)
    _run("test_column_count_boundary", test_column_count_boundary, failed)
    _run("test_max_rows_for_columns", test_max_rows_for_columns, failed)
    _run("test_cell_budget_error_names_rows_columns_cells_and_bytes", test_cell_budget_error_names_rows_columns_cells_and_bytes, failed)
    _run("test_arrow_string_bytes_boundary", test_arrow_string_bytes_boundary, failed)
    _run("test_jsonl_carry_boundary", test_jsonl_carry_boundary, failed)
    if len(failed) > 0:
        raise Error(String(len(failed)) + " case(s) failed")
    print("input_limits: ALL CASES PASS")
