# =============================================================================
# EngineError unit tests
# =============================================================================
#
# Tests for the structured engine error type.
# Covers:
#   1. Error code constants are unique.
#   2. Factory functions produce correct codes.
#   3. to_error() produces correctly formatted Error strings.
#   4. from_error() wraps generic errors as ERR_PROCESSOR.
#   5. Predicate methods (is_io, is_schema, etc.).
#   6. UDF and join predicate errors carry name + detail.
#   7. Writable produces non-empty output.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_core.engine_error import (
    EngineError,
    ERR_ARROW,
    ERR_IO,
    ERR_PROCESSOR,
    ERR_ENCODE_POOL,
    ERR_WRITER,
    ERR_SCHEMA,
    ERR_READER_PANIC,
    ERR_WRITER_PANIC,
    ERR_FORMAT,
    ERR_INVALID_ARGUMENT,
    ERR_UDF,
    ERR_UDF_PANIC,
    ERR_UDF_ROW_COUNT,
    ERR_JOIN_PREDICATE,
    ERR_JOIN_PREDICATE_PANIC,
    ERR_JOIN_PREDICATE_ROW_COUNT,
    arrow_error,
    io_error,
    processor_error,
    encode_pool_error,
    writer_error,
    schema_error,
    reader_panic_error,
    writer_panic_error,
    format_error,
    invalid_argument_error,
    udf_error,
    udf_panic_error,
    udf_row_count_error,
    join_predicate_error,
    join_predicate_panic_error,
    join_predicate_row_count_error,
)


# --- Error code uniqueness ---------------------------------------------------

def test_error_codes_unique() raises:
    """All 16 error codes are distinct."""
    var codes: List[Int] = [
        ERR_ARROW,
        ERR_IO,
        ERR_PROCESSOR,
        ERR_ENCODE_POOL,
        ERR_WRITER,
        ERR_SCHEMA,
        ERR_READER_PANIC,
        ERR_WRITER_PANIC,
        ERR_FORMAT,
        ERR_INVALID_ARGUMENT,
        ERR_UDF,
        ERR_UDF_PANIC,
        ERR_UDF_ROW_COUNT,
        ERR_JOIN_PREDICATE,
        ERR_JOIN_PREDICATE_PANIC,
        ERR_JOIN_PREDICATE_ROW_COUNT,
    ]
    # Check each pair for uniqueness.
    for i in range(len(codes)):
        for j in range(i + 1, len(codes)):
            assert_true(
                codes[i] != codes[j],
                "codes " + String(i) + " and " + String(j) + " are not unique",
            )


# --- Factory functions -------------------------------------------------------

def test_arrow_error_code() raises:
    var e = arrow_error("bad array")
    assert_equal(e.code, ERR_ARROW)
    assert_equal(e.message, "bad array")


def test_io_error_code() raises:
    var e = io_error("file not found")
    assert_equal(e.code, ERR_IO)
    assert_equal(e.message, "file not found")


def test_processor_error_code() raises:
    var e = processor_error("pipeline failed")
    assert_equal(e.code, ERR_PROCESSOR)


def test_encode_pool_error_code() raises:
    var e = encode_pool_error("pool exhausted")
    assert_equal(e.code, ERR_ENCODE_POOL)


def test_writer_error_code() raises:
    var e = writer_error("write failed")
    assert_equal(e.code, ERR_WRITER)


def test_schema_error_code() raises:
    var e = schema_error("column mismatch")
    assert_equal(e.code, ERR_SCHEMA)


def test_reader_panic_error_code() raises:
    var e = reader_panic_error()
    assert_equal(e.code, ERR_READER_PANIC)


def test_writer_panic_error_code() raises:
    var e = writer_panic_error()
    assert_equal(e.code, ERR_WRITER_PANIC)


def test_format_error_code() raises:
    var e = format_error("invalid magic bytes")
    assert_equal(e.code, ERR_FORMAT)


def test_invalid_argument_error_code() raises:
    var e = invalid_argument_error("negative batch size")
    assert_equal(e.code, ERR_INVALID_ARGUMENT)


# --- UDF errors with name context --------------------------------------------

def test_udf_error_with_name() raises:
    var e = udf_error("my_udf", "null input")
    assert_equal(e.code, ERR_UDF)
    assert_equal(e.name, "my_udf")
    assert_equal(e.message, "null input")


def test_udf_panic_error_with_name() raises:
    var e = udf_panic_error("my_udf", "segfault")
    assert_equal(e.code, ERR_UDF_PANIC)
    assert_equal(e.name, "my_udf")


def test_udf_row_count_error_detail() raises:
    var e = udf_row_count_error("my_udf", 100, 50)
    assert_equal(e.code, ERR_UDF_ROW_COUNT)
    assert_equal(e.name, "my_udf")
    assert_true("100" in e.message, "message should contain input_rows")
    assert_true("50" in e.message, "message should contain output_rows")
    assert_true(e.detail.byte_length() > 0, "detail should be non-empty")


# --- Join predicate errors ---------------------------------------------------

def test_join_predicate_error_with_name() raises:
    var e = join_predicate_error("range_check", "out of bounds")
    assert_equal(e.code, ERR_JOIN_PREDICATE)
    assert_equal(e.name, "range_check")


def test_join_predicate_panic_error_with_name() raises:
    var e = join_predicate_panic_error("range_check", "stack overflow")
    assert_equal(e.code, ERR_JOIN_PREDICATE_PANIC)
    assert_equal(e.name, "range_check")


def test_join_predicate_row_count_error_detail() raises:
    var e = join_predicate_row_count_error("range_check", 200, 100)
    assert_equal(e.code, ERR_JOIN_PREDICATE_ROW_COUNT)
    assert_true("200" in e.message)
    assert_true("100" in e.message)


# --- to_error() formatting ---------------------------------------------------

def test_to_error_simple() raises:
    """Converts to_error() for a simple error to [CodeName] message."""
    var e = io_error("disk full")
    var err = e.to_error()
    var s = String(err)
    assert_true("[IO]" in s, "should contain [IO], got: " + s)
    assert_true("disk full" in s, "should contain message")


def test_to_error_with_name() raises:
    """Converts to_error() for named errors to [CodeName] 'name': message."""
    var e = udf_error("my_udf", "null input")
    var err = e.to_error()
    var s = String(err)
    assert_true("[UDF]" in s, "should contain [UDF]")
    assert_true("'my_udf'" in s, "should contain name in quotes")
    assert_true("null input" in s, "should contain message")


# --- from_error() wrapping ---------------------------------------------------

def test_from_error_wraps_as_processor() raises:
    """Wraps generic Error as ERR_PROCESSOR via from_error()."""
    var err = Error("something broke")
    var e = EngineError.from_error(err)
    assert_equal(e.code, ERR_PROCESSOR)
    assert_true("something broke" in e.message)


# --- Predicate methods -------------------------------------------------------

def test_is_io() raises:
    assert_true(io_error("x").is_io())
    assert_true(not arrow_error("x").is_io())


def test_is_schema() raises:
    assert_true(schema_error("x").is_schema())
    assert_true(not io_error("x").is_schema())


def test_is_format() raises:
    assert_true(format_error("x").is_format())
    assert_true(not io_error("x").is_format())


def test_is_panic() raises:
    assert_true(reader_panic_error().is_panic())
    assert_true(writer_panic_error().is_panic())
    assert_true(not io_error("x").is_panic())


def test_is_udf() raises:
    assert_true(udf_error("f", "m").is_udf())
    assert_true(udf_panic_error("f", "m").is_udf())
    assert_true(udf_row_count_error("f", 1, 2).is_udf())
    assert_true(not io_error("x").is_udf())


def test_is_join_predicate() raises:
    assert_true(join_predicate_error("p", "m").is_join_predicate())
    assert_true(join_predicate_panic_error("p", "m").is_join_predicate())
    assert_true(join_predicate_row_count_error("p", 1, 2).is_join_predicate())
    assert_true(not io_error("x").is_join_predicate())


# --- Writable ----------------------------------------------------------------

def test_writable() raises:
    """EngineError can be printed."""
    var e = udf_error("my_udf", "null input")
    var s = String(e)
    assert_true(s.byte_length() > 0, "str() should produce non-empty output")
    assert_true("EngineError" in s, "output should contain 'EngineError'")
    assert_true("UDF" in s, "output should contain error code name")
    assert_true("my_udf" in s, "output should contain name")


# --- Entry point -------------------------------------------------------------

def main() raises:
    test_error_codes_unique()
    test_arrow_error_code()
    test_io_error_code()
    test_processor_error_code()
    test_encode_pool_error_code()
    test_writer_error_code()
    test_schema_error_code()
    test_reader_panic_error_code()
    test_writer_panic_error_code()
    test_format_error_code()
    test_invalid_argument_error_code()
    test_udf_error_with_name()
    test_udf_panic_error_with_name()
    test_udf_row_count_error_detail()
    test_join_predicate_error_with_name()
    test_join_predicate_panic_error_with_name()
    test_join_predicate_row_count_error_detail()
    test_to_error_simple()
    test_to_error_with_name()
    test_from_error_wraps_as_processor()
    test_is_io()
    test_is_schema()
    test_is_format()
    test_is_panic()
    test_is_udf()
    test_is_join_predicate()
    test_writable()
    print("test_engine_error: 27 tests passed")
