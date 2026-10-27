# =============================================================================
# test_kafka_crc32c_portable.mojo
#   The table-driven CRC-32C path (`crc32c_span_portable`), which
#   `crc32c_span` takes only on targets without the hardware instruction:
#   known vectors, and agreement with `crc32c_span` (the hardware path on
#   x86-64 and macOS arm64) over many lengths of pseudo-random bytes.
# =============================================================================

from std.testing import assert_equal

from komira_kafka_server.wire.crc32c import (
    crc32c_span,
    crc32c_span_portable,
    crc32c_list,
)


def _bytes(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _filled(n: Int, v: UInt8) -> List[UInt8]:
    var out = List[UInt8]()
    for _ in range(n):
        out.append(v)
    return out^


def _check(data: List[UInt8], want: Int) raises:
    # Both paths, and the list wrapper, give the vector's value.
    assert_equal(Int(crc32c_span_portable(Span(data))), want)
    assert_equal(Int(crc32c_span(Span(data))), want)
    assert_equal(Int(crc32c_list(data)), want)


def test_portable_standard_vectors() raises:
    # "123456789" is the check value of CRC-32C.
    _check(_bytes("123456789"), 0xE3069283)
    _check(List[UInt8](), 0)
    _check(_filled(1, UInt8(0)), 0x527D5351)


def test_portable_rfc3720_vectors() raises:
    # RFC 3720 (iSCSI), appendix B.4: the CRC-32C examples.
    _check(_filled(32, UInt8(0x00)), 0x8A9136AA)
    _check(_filled(32, UInt8(0xFF)), 0x62A8AB43)

    var up = List[UInt8]()
    var down = List[UInt8]()
    for i in range(32):
        up.append(UInt8(i))
        down.append(UInt8(31 - i))
    _check(up, 0x46DD794E)
    _check(down, 0x113FDB5C)

    # The SCSI Read (10) command PDU, 48 bytes.
    var pdu = List[UInt8]()
    var raw: List[Int] = [
        0x01, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00,
        0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x18,
        0x28, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]
    for i in range(len(raw)):
        pdu.append(UInt8(raw[i]))
    assert_equal(len(pdu), 48)
    _check(pdu, 0xD9963A56)


def test_portable_matches_hardware_on_random_inputs() raises:
    # A fixed linear congruential generator: the same bytes on every run.
    var state = UInt64(0x9E3779B97F4A7C15)
    var lengths = List[Int]()
    for n in range(0, 70):  # every tail length around the 8-byte folds
        lengths.append(n)
    lengths.append(255)
    lengths.append(256)
    lengths.append(1000)
    lengths.append(4097)
    for k in range(len(lengths)):
        var data = List[UInt8]()
        for _ in range(lengths[k]):
            state = state * UInt64(6364136223846793005) + UInt64(
                1442695040888963407
            )
            data.append(UInt8((state >> UInt64(33)) & UInt64(0xFF)))
        assert_equal(
            Int(crc32c_span_portable(Span(data))),
            Int(crc32c_span(Span(data))),
        )


def test_portable_reads_only_the_span() raises:
    # A sub-span of a longer buffer: bytes outside it do not enter the sum.
    var data = _bytes("xx123456789yy")
    var sub = Span(data)[2:11]
    assert_equal(Int(crc32c_span_portable(sub)), 0xE3069283)
    assert_equal(Int(crc32c_span(sub)), 0xE3069283)


def main() raises:
    test_portable_standard_vectors()
    test_portable_rfc3720_vectors()
    test_portable_matches_hardware_on_random_inputs()
    test_portable_reads_only_the_span()
    print("OK test_kafka_crc32c_portable")
