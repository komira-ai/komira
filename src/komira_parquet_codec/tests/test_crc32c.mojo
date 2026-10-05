# CRC-32C (Castagnoli) against published check values: the CRC catalogue's
# check value for the nine bytes "123456789", and the three 32-byte vectors
# of RFC 3720 (iSCSI) appendix B.4.
from std.testing import TestSuite, assert_equal

from komira_parquet_codec import crc32c


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def test_check_value() raises:
    assert_equal(Int(crc32c(Span(_bytes("123456789")))), 0xE3069283)


def test_empty() raises:
    var empty = List[UInt8]()
    assert_equal(Int(crc32c(Span(empty))), 0)


def test_rfc3720_vectors() raises:
    var zeros = List[UInt8]()
    var ones = List[UInt8]()
    var incr = List[UInt8]()
    var decr = List[UInt8]()
    for i in range(32):
        zeros.append(0)
        ones.append(0xFF)
        incr.append(UInt8(i))
        decr.append(UInt8(31 - i))
    assert_equal(Int(crc32c(Span(zeros))), 0x8A9136AA)
    assert_equal(Int(crc32c(Span(ones))), 0x62A8AB43)
    assert_equal(Int(crc32c(Span(incr))), 0x46DD794E)
    assert_equal(Int(crc32c(Span(decr))), 0x113FDB5C)


def test_every_tail_length() raises:
    # The loop takes 4 bytes at a time: lengths 1..8 cover each remainder.
    # Prefixes of "123456789" checked against a byte-at-a-time reference.
    var all = _bytes("123456789")
    for n in range(1, 10):
        var crc = UInt32(0xFFFFFFFF)
        for i in range(n):
            crc ^= UInt32(all[i])
            for _ in range(8):
                crc = (crc >> 1) ^ (UInt32(0x82F63B78) if (crc & 1) != 0 else UInt32(0))
        assert_equal(
            Int(crc32c(Span(all)[0:n])), Int(crc ^ 0xFFFFFFFF), "length " + String(n)
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
