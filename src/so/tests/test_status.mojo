# The status codes, the ABI version and the two-call buffer test.
#
# Rows: the seven codes have the values the C header documents (0, -1 .. -6),
# the six steps are 0 .. 5 in pipeline order,
# the version is major * 1000 + minor and decodes back to the two parts, and
# buffer_status is TOO_SMALL exactly when the capacity is below the length
# (zero capacity for a non-empty text, one byte short) and OK at the length,
# above it, and for an empty text with no capacity; input_length_status accepts
# zero and exactly KOMIRA_MAX_INPUT_BYTES (64 MiB) and refuses one byte more,
# the largest unsigned value and the unsigned image of -1.
from std.testing import assert_equal

from so import (
    ABI_MAJOR,
    ABI_MINOR,
    KOMIRA_ERR_BUFFER_TOO_SMALL,
    KOMIRA_ERR_CANCELLED,
    KOMIRA_ERR_ENGINE,
    KOMIRA_ERR_NULL_ARG,
    KOMIRA_ERR_NULL_CTX,
    KOMIRA_ERR_TOO_LARGE,
    KOMIRA_MAX_INPUT_BYTES,
    KOMIRA_OK,
    KOMIRA_STEP_BIND,
    KOMIRA_STEP_EXECUTE,
    KOMIRA_STEP_LOWER,
    KOMIRA_STEP_NONE,
    KOMIRA_STEP_OPTIMIZE,
    KOMIRA_STEP_PARSE,
    abi_version,
    buffer_status,
    input_length_status,
)


def test_code_values() raises:
    assert_equal(KOMIRA_OK, Int32(0))
    assert_equal(KOMIRA_ERR_NULL_CTX, Int32(-1))
    assert_equal(KOMIRA_ERR_NULL_ARG, Int32(-2))
    assert_equal(KOMIRA_ERR_ENGINE, Int32(-3))
    assert_equal(KOMIRA_ERR_BUFFER_TOO_SMALL, Int32(-4))
    assert_equal(KOMIRA_ERR_TOO_LARGE, Int32(-5))
    assert_equal(KOMIRA_ERR_CANCELLED, Int32(-6))


def test_step_values() raises:
    assert_equal(KOMIRA_STEP_NONE, Int32(0))
    assert_equal(KOMIRA_STEP_PARSE, Int32(1))
    assert_equal(KOMIRA_STEP_BIND, Int32(2))
    assert_equal(KOMIRA_STEP_OPTIMIZE, Int32(3))
    assert_equal(KOMIRA_STEP_LOWER, Int32(4))
    assert_equal(KOMIRA_STEP_EXECUTE, Int32(5))


def test_version_scheme() raises:
    var v = abi_version()
    assert_equal(v, Int32(1011))
    assert_equal(v // Int32(1000), ABI_MAJOR)
    assert_equal(v % Int32(1000), ABI_MINOR)


def test_buffer_status() raises:
    assert_equal(buffer_status(5, UInt64(0)), KOMIRA_ERR_BUFFER_TOO_SMALL)
    assert_equal(buffer_status(5, UInt64(4)), KOMIRA_ERR_BUFFER_TOO_SMALL)
    assert_equal(buffer_status(5, UInt64(5)), KOMIRA_OK)
    assert_equal(buffer_status(5, UInt64(64)), KOMIRA_OK)
    assert_equal(buffer_status(0, UInt64(0)), KOMIRA_OK)


def test_input_length_status() raises:
    assert_equal(KOMIRA_MAX_INPUT_BYTES, UInt64(67108864))
    assert_equal(input_length_status(UInt64(0)), KOMIRA_OK)
    assert_equal(input_length_status(UInt64(1)), KOMIRA_OK)
    assert_equal(input_length_status(KOMIRA_MAX_INPUT_BYTES), KOMIRA_OK)
    assert_equal(
        input_length_status(KOMIRA_MAX_INPUT_BYTES + UInt64(1)),
        KOMIRA_ERR_TOO_LARGE,
    )
    assert_equal(input_length_status(UInt64.MAX), KOMIRA_ERR_TOO_LARGE)
    assert_equal(
        input_length_status(UInt64(0) - UInt64(1)), KOMIRA_ERR_TOO_LARGE
    )


def main() raises:
    test_code_values()
    test_step_values()
    test_input_length_status()
    test_version_scheme()
    test_buffer_status()
    print("OK")
