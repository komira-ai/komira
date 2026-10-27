# The status codes, the ABI version and the two-call buffer test.
#
# Rows: the five codes have the values the C header documents (0, -1 .. -4),
# the version is major * 1000 + minor and decodes back to the two parts, and
# buffer_status is TOO_SMALL exactly when the capacity is below the length
# (zero capacity for a non-empty text, one byte short) and OK at the length,
# above it, and for an empty text with no capacity.
from std.testing import assert_equal

from komira_so import (
    ABI_MAJOR,
    ABI_MINOR,
    KOMIRA_ERR_BUFFER_TOO_SMALL,
    KOMIRA_ERR_ENGINE,
    KOMIRA_ERR_NULL_ARG,
    KOMIRA_ERR_NULL_CTX,
    KOMIRA_OK,
    abi_version,
    buffer_status,
)


def test_code_values() raises:
    assert_equal(KOMIRA_OK, Int32(0))
    assert_equal(KOMIRA_ERR_NULL_CTX, Int32(-1))
    assert_equal(KOMIRA_ERR_NULL_ARG, Int32(-2))
    assert_equal(KOMIRA_ERR_ENGINE, Int32(-3))
    assert_equal(KOMIRA_ERR_BUFFER_TOO_SMALL, Int32(-4))


def test_version_scheme() raises:
    var v = abi_version()
    assert_equal(v, Int32(1001))
    assert_equal(v // Int32(1000), ABI_MAJOR)
    assert_equal(v % Int32(1000), ABI_MINOR)


def test_buffer_status() raises:
    assert_equal(buffer_status(5, UInt64(0)), KOMIRA_ERR_BUFFER_TOO_SMALL)
    assert_equal(buffer_status(5, UInt64(4)), KOMIRA_ERR_BUFFER_TOO_SMALL)
    assert_equal(buffer_status(5, UInt64(5)), KOMIRA_OK)
    assert_equal(buffer_status(5, UInt64(64)), KOMIRA_OK)
    assert_equal(buffer_status(0, UInt64(0)), KOMIRA_OK)


def main() raises:
    test_code_values()
    test_version_scheme()
    test_buffer_status()
    print("OK")
