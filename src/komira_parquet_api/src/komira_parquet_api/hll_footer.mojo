# =============================================================================
# Where a column chunk's HyperLogLog registers live in a Parquet footer
# =============================================================================
#
# `Statistics.hll_registers` is not part of the Parquet format. Its old
# location, Statistics field 9, is parquet.thrift's `optional i64 nan_count`,
# so this module fixes the location and the rule for field 9 before any
# reader or writer encodes either:
#
# - The registers travel in the column chunk's own key-value metadata
#   (`ColumnMetaData.key_value_metadata`, parquet.thrift ColumnMetaData field
#   8), under the key `HLL_REGISTERS_KEY`. A reader that does not know the key
#   skips it, as it skips any key-value pair; the per-chunk granularity is the
#   one field 9 had.
# - The value is text, one character per register: register value r (0 to
#   53) is character r of the RFC 4648 base64 alphabet (`A`-`Z` are 0-25,
#   `a`-`z` 26-51, `0` 52, `1` 53). parquet.thrift declares KeyValue.value a
#   `string`, which readers may decode as UTF-8, so raw register bytes are not
#   safe there; this text is ASCII and exactly as long as the 4096 bytes it
#   replaces.
# - Statistics field 9 is `nan_count` and nothing else. A reader decodes it
#   only when its Thrift compact type is i64 (`statistics_field_9_is_nan_count`)
#   and skips it otherwise; a binary field 9 (the old location) is never taken
#   as registers.
#
# The register constants restate komira_collections' HyperLogLog (precision 12,
# 4096 registers, largest value 53); this package depends on nothing, so they
# are repeated here rather than imported.
# =============================================================================

from .metadata import KeyValue


# The key-value metadata key a column chunk's HLL registers are stored under.
comptime HLL_REGISTERS_KEY = "komira.hll_registers.p12"

# Registers in a precision-12 sketch: 1 << 12.
comptime HLL_REGISTER_COUNT: Int = 4096

# The largest register value of a precision-12 sketch over 64-bit hashes.
comptime HLL_MAX_REGISTER: Int = 53

# parquet.thrift Statistics field 9: `optional i64 nan_count`.
comptime STATISTICS_NAN_COUNT_FIELD_ID: Int = 9

# The Thrift compact protocol's type id for i64 (its BINARY is 8).
comptime THRIFT_COMPACT_TYPE_I64: UInt8 = 6

# Character r is register value r.
comptime _REGISTER_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz01"


def statistics_field_9_is_nan_count(compact_type: UInt8) -> Bool:
    """Whether a Statistics field 9 of this Thrift compact type is `nan_count`.

    True only for i64. A reader decodes field 9 as `nan_count` when this is
    true and skips the field otherwise; no wire type of field 9 is HLL
    registers.

    Args:
        compact_type: The type id from the field header (the low four bits).

    Returns:
        True when `compact_type` is the compact protocol's i64.
    """
    return compact_type == THRIFT_COMPACT_TYPE_I64


def _register_of(c: UInt8) -> Int:
    """The register value character `c` encodes, or -1 if it encodes none."""
    var v = Int(c)
    if v >= ord("A") and v <= ord("Z"):
        return v - ord("A")
    if v >= ord("a") and v <= ord("z"):
        return v - ord("a") + 26
    if v == ord("0"):
        return 52
    if v == ord("1"):
        return 53
    return -1


def hll_registers_to_key_value(registers: Span[UInt8, _]) raises -> KeyValue:
    """The key-value pair that carries `registers` in a column chunk's metadata.

    Args:
        registers: A precision-12 register array: 4096 values, each 0 to 53.

    Returns:
        `KeyValue(HLL_REGISTERS_KEY, text)`, one character per register.

    Raises:
        If `registers` does not hold 4096 values or one exceeds 53.
    """
    if len(registers) != HLL_REGISTER_COUNT:
        raise Error(
            "HLL registers: expected "
            + String(HLL_REGISTER_COUNT)
            + " registers, got "
            + String(len(registers))
        )
    var alphabet = String(_REGISTER_ALPHABET)
    var text = String(capacity=HLL_REGISTER_COUNT)
    for i in range(HLL_REGISTER_COUNT):
        var r = Int(registers[i])
        if r > HLL_MAX_REGISTER:
            raise Error(
                "HLL registers: register "
                + String(i)
                + " is "
                + String(r)
                + ", above the largest value "
                + String(HLL_MAX_REGISTER)
            )
        text += String(alphabet[byte = r : r + 1])
    return KeyValue(String(HLL_REGISTERS_KEY), text^)


def hll_registers_from_key_values(
    key_values: List[KeyValue],
) raises -> Optional[List[UInt8]]:
    """The HLL registers a column chunk's key-value metadata carries, if any.

    Only the pair keyed `HLL_REGISTERS_KEY` is read; every other pair is
    ignored. A chunk without that key (a file from another writer) has no
    registers, and a reader falls back to `distinct_count`.

    Args:
        key_values: `ColumnMetaData.key_value_metadata` of one column chunk.

    Returns:
        The 4096 register values, or None when the key is absent.

    Raises:
        If the key appears more than once, has no value, or its value is not
        4096 characters of the register alphabet. A reader that would rather
        drop a damaged sketch than fail catches this and treats the chunk as
        having none.
    """
    var found = -1
    for i in range(len(key_values)):
        if key_values[i].key == HLL_REGISTERS_KEY:
            if found >= 0:
                raise Error(
                    "HLL registers: key "
                    + String(HLL_REGISTERS_KEY)
                    + " appears more than once"
                )
            found = i
    if found < 0:
        return None
    ref value = key_values[found].value
    if not value:
        raise Error(
            "HLL registers: key " + String(HLL_REGISTERS_KEY) + " has no value"
        )
    var text = value.value().as_bytes()
    if len(text) != HLL_REGISTER_COUNT:
        raise Error(
            "HLL registers: expected "
            + String(HLL_REGISTER_COUNT)
            + " characters, got "
            + String(len(text))
        )
    var registers = List[UInt8](capacity=HLL_REGISTER_COUNT)
    for i in range(HLL_REGISTER_COUNT):
        var r = _register_of(text[i])
        if r < 0:
            raise Error(
                "HLL registers: character "
                + String(i)
                + " (byte "
                + String(Int(text[i]))
                + ") is not a register value"
            )
        registers.append(UInt8(r))
    return registers^
