# Where a column chunk's HLL registers live in a footer, and the rule for
# Statistics field 9 (hll_footer.mojo). The registers' old location,
# Statistics field 9, is parquet.thrift's `optional i64 nan_count`; these
# tests hold the new location (ColumnMetaData.key_value_metadata,
# one base64-alphabet character per register) and the field 9 rule (only an
# i64 is nan_count, a binary is never registers).
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_parquet_api import (
    ColumnMetaData,
    CompressionCodec,
    Encoding,
    KeyValue,
    ParquetType,
    Statistics,
)
from komira_parquet_api.hll_footer import (
    HLL_MAX_REGISTER,
    HLL_REGISTER_COUNT,
    HLL_REGISTERS_KEY,
    THRIFT_COMPACT_TYPE_I64,
    hll_registers_from_key_values,
    hll_registers_to_key_value,
    statistics_field_9_is_nan_count,
)


def _registers_cycling() -> List[UInt8]:
    """4096 registers that take every value 0..53, in order, repeatedly."""
    var regs = List[UInt8](capacity=HLL_REGISTER_COUNT)
    for i in range(HLL_REGISTER_COUNT):
        regs.append(UInt8(i % (HLL_MAX_REGISTER + 1)))
    return regs^


def _text_of(n: Int, c: String) -> String:
    var s = String()
    for _ in range(n):
        s += c
    return s^


def _one(var kv: KeyValue) -> List[KeyValue]:
    var kvs = List[KeyValue]()
    kvs.append(kv^)
    return kvs^


# =============================================================================
# Statistics field 9
# =============================================================================


def test_field_9_is_nan_count_only_as_i64() raises:
    # Every compact type id (0..15): only i64 (6) is nan_count.
    for t in range(16):
        assert_equal(
            statistics_field_9_is_nan_count(UInt8(t)),
            t == 6,
            "compact type " + String(t),
        )
    assert_equal(THRIFT_COMPACT_TYPE_I64, UInt8(6))


def test_old_binary_field_9_is_not_nan_count() raises:
    # The old location wrote the registers as a binary field 9 (compact
    # type 8). A reader must skip it, not decode it as anything.
    assert_false(statistics_field_9_is_nan_count(UInt8(8)))


def test_statistics_carries_nan_count_beside_registers() raises:
    # Both fit in one Statistics value: nan_count is field 9 on the wire,
    # the registers are not a Statistics field on the wire at all.
    var stats = Statistics(
        null_count=1,
        hll_registers=_registers_cycling(),
        nan_count=7,
    )
    assert_equal(stats.nan_count.value(), 7)
    assert_equal(len(stats.hll_registers.value()), HLL_REGISTER_COUNT)
    assert_false(Statistics().nan_count)


# =============================================================================
# The key-value encoding
# =============================================================================


def test_round_trip_every_register_value() raises:
    var regs = _registers_cycling()
    var kv = hll_registers_to_key_value(regs)
    assert_equal(kv.key, String(HLL_REGISTERS_KEY))
    var back = hll_registers_from_key_values(_one(kv^))
    assert_true(Bool(back))
    ref got = back.value()
    assert_equal(len(got), HLL_REGISTER_COUNT)
    for i in range(HLL_REGISTER_COUNT):
        assert_equal(got[i], regs[i], "register " + String(i))


def test_alphabet_is_pinned() raises:
    # The text is the wire format: pin the character of each boundary value
    # so a change to the alphabet cannot round-trip silently.
    var regs = List[UInt8](capacity=HLL_REGISTER_COUNT)
    for _ in range(HLL_REGISTER_COUNT):
        regs.append(0)
    regs[1] = 25
    regs[2] = 26
    regs[3] = 51
    regs[4] = 52
    regs[5] = 53
    var kv = hll_registers_to_key_value(regs)
    ref text = kv.value.value()
    assert_equal(text.byte_length(), HLL_REGISTER_COUNT)
    assert_equal(String(text[byte=0:6]), "AZaz01")
    assert_equal(String(text[byte=6:8]), "AA")
    assert_equal(String(HLL_REGISTERS_KEY), "komira.hll_registers.p12")


def test_value_is_ascii() raises:
    var kv = hll_registers_to_key_value(_registers_cycling())
    var b = kv.value.value().as_bytes()
    for i in range(len(b)):
        assert_true(b[i] < 128, "byte " + String(i))


def test_encode_refuses_wrong_length() raises:
    var short = List[UInt8](capacity=HLL_REGISTER_COUNT - 1)
    for _ in range(HLL_REGISTER_COUNT - 1):
        short.append(0)
    with assert_raises(contains="expected 4096 registers"):
        _ = hll_registers_to_key_value(short)
    var long = _registers_cycling()
    long.append(0)
    with assert_raises(contains="expected 4096 registers"):
        _ = hll_registers_to_key_value(long)


def test_encode_refuses_register_above_53() raises:
    var regs = _registers_cycling()
    regs[4095] = 54
    with assert_raises(contains="register 4095 is 54"):
        _ = hll_registers_to_key_value(regs)


# =============================================================================
# Reading key-value metadata
# =============================================================================


def test_absent_key_is_none_and_other_keys_are_ignored() raises:
    var kvs = List[KeyValue]()
    kvs.append(KeyValue("ARROW:schema", String("not registers")))
    kvs.append(KeyValue("komira.hll_registers.p14", _text_of(4096, "A")))
    kvs.append(KeyValue("other", None))
    assert_false(Bool(hll_registers_from_key_values(kvs)))
    assert_false(Bool(hll_registers_from_key_values(List[KeyValue]())))


def test_key_found_among_others() raises:
    var kvs = List[KeyValue]()
    kvs.append(KeyValue("ARROW:schema", String("x")))
    kvs.append(hll_registers_to_key_value(_registers_cycling()))
    kvs.append(KeyValue("after", String("y")))
    var got = hll_registers_from_key_values(kvs)
    assert_equal(got.value()[HLL_MAX_REGISTER], UInt8(HLL_MAX_REGISTER))


def test_decode_refuses_missing_value() raises:
    with assert_raises(contains="has no value"):
        _ = hll_registers_from_key_values(
            _one(KeyValue(String(HLL_REGISTERS_KEY), None))
        )


def test_decode_refuses_wrong_length() raises:
    with assert_raises(contains="expected 4096 characters, got 4095"):
        _ = hll_registers_from_key_values(
            _one(KeyValue(String(HLL_REGISTERS_KEY), _text_of(4095, "A")))
        )
    with assert_raises(contains="expected 4096 characters, got 0"):
        _ = hll_registers_from_key_values(
            _one(KeyValue(String(HLL_REGISTERS_KEY), String("")))
        )


def test_decode_refuses_characters_outside_the_register_range() raises:
    # "2" would be 54 and "+", "/" 62 and 63 in base64: above the largest
    # register. "=" is base64 padding. A raw binary byte is what the old
    # field 9 location held.
    var bad: List[String] = ["2", "9", "+", "/", "=", " ", "@", "[", "`", "{"]
    for j in range(len(bad)):
        var text = _text_of(4095, "A") + bad[j]
        with assert_raises(contains="character 4095"):
            _ = hll_registers_from_key_values(
                _one(KeyValue(String(HLL_REGISTERS_KEY), text^))
            )


def test_decode_refuses_duplicate_key() raises:
    var kvs = List[KeyValue]()
    kvs.append(hll_registers_to_key_value(_registers_cycling()))
    kvs.append(hll_registers_to_key_value(_registers_cycling()))
    with assert_raises(contains="appears more than once"):
        _ = hll_registers_from_key_values(kvs)


# =============================================================================
# Column chunks
# =============================================================================


def _chunk(
    var stats: Statistics, var kvs: Optional[List[KeyValue]]
) -> ColumnMetaData:
    var encodings: List[Encoding] = [Encoding.PLAIN]
    var path: List[String] = ["x"]
    return ColumnMetaData(
        type=ParquetType.DOUBLE,
        encodings=encodings^,
        path_in_schema=path^,
        codec=CompressionCodec.UNCOMPRESSED,
        num_values=100,
        total_uncompressed_size=800,
        total_compressed_size=800,
        data_page_offset=4,
        statistics=stats^,
        key_value_metadata=kvs^,
    )


def test_chunk_from_another_writer_has_nan_count_and_no_registers() raises:
    # Another writer's DOUBLE chunk: nan_count set (field 9, i64), its own
    # key-value metadata, no registers key. The registers read as absent
    # (fall back to distinct_count) and nan_count is a count, not a sketch.
    var kvs = List[KeyValue]()
    kvs.append(KeyValue("writer.note", String("x")))
    var cmd = _chunk(Statistics(null_count=0, distinct_count=90, nan_count=3), kvs^)
    assert_equal(cmd.statistics.value().nan_count.value(), 3)
    assert_false(Bool(cmd.statistics.value().hll_registers))
    assert_false(Bool(hll_registers_from_key_values(cmd.key_value_metadata.value())))
    assert_false(Bool(_chunk(Statistics(), None).key_value_metadata))


def test_chunk_carries_registers_in_its_key_value_metadata() raises:
    var regs = _registers_cycling()
    var cmd = _chunk(
        Statistics(null_count=0, nan_count=0),
        _one(hll_registers_to_key_value(regs)),
    )
    var got = hll_registers_from_key_values(cmd.key_value_metadata.value())
    assert_equal(len(got.value()), HLL_REGISTER_COUNT)
    assert_equal(got.value()[100], regs[100])
    assert_equal(cmd.statistics.value().nan_count.value(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
