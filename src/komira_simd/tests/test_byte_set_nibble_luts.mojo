# =============================================================================
# build_byte_set_nibble_luts + byte_find_in_set_u8x16 / _u8x32: exact
# set membership over every byte value.
# =============================================================================
#
# Oracle: a 256-entry membership table filled by a scalar loop over the
# needle list. It shares nothing with the LUT builder or the nibble
# lookup. Every check runs all 256 byte values through the SIMD lookup
# (16 chunks at width 16, 8 chunks at width 32) and requires lane k to be
# non-zero iff the byte is in the table.
#
# What each test catches:
#   - single_byte_set: a builder whose low- and high-nibble entries do not
#     share a bit for the needle (the byte is not found), or share bits
#     with other bytes (false positives). Runs all 256 one-byte sets.
#   - csv_sets: the RFC-4180 and Excel-style CSV needle sets the module
#     header names (`,` `\n` `\r` `"` `\\`).
#   - full_high_nibble_rows / full_low_nibble_columns: sets that need
#     more than 8 distinct nibbles on one side, so the builder must group
#     by the other side.
#   - unrepresentable_set_raises: more than 8 distinct high nibbles AND
#     more than 8 distinct low nibbles cannot be encoded exactly in 8-bit
#     LUT entries; the builder must refuse rather than return LUTs that
#     give false positives or misses.
#   - random_sets: 2000 seeded sets of 0..24 bytes; representable sets
#     must match the oracle exactly, the others must raise.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_simd.byte_class.byte_find_any_of import (
    build_byte_set_nibble_luts,
    byte_find_in_set_u8x16,
    byte_find_in_set_u8x32,
)


def _membership(needles: List[UInt8]) -> List[Bool]:
    var table = List[Bool](length=256, fill=False)
    for i in range(len(needles)):
        table[Int(needles[i])] = True
    return table^


def _distinct_nibbles(needles: List[UInt8], shift: UInt8) -> Int:
    var seen = List[Bool](length=16, fill=False)
    var n = 0
    for i in range(len(needles)):
        var nib = Int((needles[i] >> shift) & UInt8(0x0F))
        if not seen[nib]:
            seen[nib] = True
            n += 1
    return n


def _representable(needles: List[UInt8]) -> Bool:
    return (
        _distinct_nibbles(needles, UInt8(4)) <= 8
        or _distinct_nibbles(needles, UInt8(0)) <= 8
    )


def _check_exact(needles: List[UInt8], label: String) raises:
    """Every byte 0..255 through both widths agrees with the oracle."""
    var table = _membership(needles)
    var luts = build_byte_set_nibble_luts(needles)
    var lo = luts[0]
    var hi = luts[1]
    for blk in range(16):
        var chunk = SIMD[DType.uint8, 16](0)
        for k in range(16):
            chunk[k] = UInt8(blk * 16 + k)
        var r = byte_find_in_set_u8x16(lo, hi, chunk)
        for k in range(16):
            var b = blk * 16 + k
            assert_equal(
                r[k] != 0,
                table[b],
                String(label, ": u8x16 byte ", b, " in-set=", table[b]),
            )
    for blk in range(8):
        var chunk = SIMD[DType.uint8, 32](0)
        for k in range(32):
            chunk[k] = UInt8(blk * 32 + k)
        var r = byte_find_in_set_u8x32(lo, hi, chunk)
        for k in range(32):
            var b = blk * 32 + k
            assert_equal(
                r[k] != 0,
                table[b],
                String(label, ": u8x32 byte ", b, " in-set=", table[b]),
            )


def _build_error(needles: List[UInt8]) -> String:
    try:
        _ = build_byte_set_nibble_luts(needles)
    except e:
        return String(e)
    return String("no error")


def test_single_byte_set() raises:
    for c in range(256):
        var needles = List[UInt8]()
        needles.append(UInt8(c))
        _check_exact(needles, String("set {", c, "}"))


def test_empty_set_matches_nothing() raises:
    _check_exact(List[UInt8](), "empty set")


def test_csv_sets() raises:
    var rfc = List[UInt8]()
    for c in [0x2C, 0x0A, 0x0D, 0x22]:  # , \n \r "
        rfc.append(UInt8(c))
    _check_exact(rfc, "RFC-4180 set")
    var excel = List[UInt8]()
    for c in [0x2C, 0x0A, 0x0D, 0x22, 0x5C]:  # , \n \r " \\
        excel.append(UInt8(c))
    _check_exact(excel, "Excel set")
    # Duplicates change nothing.
    excel.append(UInt8(0x2C))
    excel.append(UInt8(0x5C))
    _check_exact(excel, "Excel set with duplicates")


def test_full_high_nibble_rows() raises:
    # 8 high nibbles (0x0_, 0x2_, ..., 0xE_), all 16 low nibbles: 128
    # needles, every low nibble used, so grouping is by high nibble.
    var needles = List[UInt8]()
    for h in range(0, 16, 2):
        for l in range(16):
            needles.append(UInt8(h * 16 + l))
    _check_exact(needles, "8 full rows")


def test_full_low_nibble_columns() raises:
    # 8 low nibbles (0x_1, 0x_3, ..., 0x_F), all 16 high nibbles: grouping
    # must be by low nibble.
    var needles = List[UInt8]()
    for l in range(1, 16, 2):
        for h in range(16):
            needles.append(UInt8(h * 16 + l))
    _check_exact(needles, "8 full columns")
    # A whole column of one low nibble plus a high byte: 16 high nibbles,
    # 2 low nibbles.
    var col = List[UInt8]()
    for h in range(16):
        col.append(UInt8(h * 16))
    col.append(UInt8(0xFF))
    _check_exact(col, "column 0x_0 plus 0xFF")


def test_unrepresentable_set_raises() raises:
    # The diagonal 0x00, 0x11, ..., 0x88: 9 distinct nibbles on each side.
    var needles = List[UInt8]()
    for n in range(9):
        needles.append(UInt8(n * 17))
    var err = _build_error(needles)
    assert_true(
        "more than 8 distinct" in err,
        String("9-byte diagonal: want a refusal, got: ", err),
    )
    # One fewer is representable and exact.
    _ = needles.pop()
    _check_exact(needles, "8-byte diagonal")


def test_random_sets() raises:
    var x = UInt64(0x9E3779B97F4A7C15)
    var exact = 0
    var refused = 0
    for trial in range(2000):
        x = x * UInt64(6364136223846793005) + UInt64(1442695040888963407)
        var size = Int(x >> UInt64(59)) % 25
        var needles = List[UInt8]()
        for _ in range(size):
            x = x * UInt64(6364136223846793005) + UInt64(1442695040888963407)
            needles.append(UInt8(x >> UInt64(56)))
        if _representable(needles):
            _check_exact(needles, String("random set ", trial))
            exact += 1
        else:
            var err = _build_error(needles)
            assert_true(
                "more than 8 distinct" in err,
                String("random set ", trial, ": want a refusal, got: ", err),
            )
            refused += 1
    # Both branches ran: the sweep is not vacuous on either side.
    assert_true(exact > 100, String("exact sets: ", exact))
    assert_true(refused > 100, String("refused sets: ", refused))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
