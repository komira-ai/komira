# Snappy short-offset (2..15) copies, which expand a repeating pattern (RLE),
# and a long literal with a one-byte extended length, on hand-built blobs.

from std.memory import UnsafePointer, alloc, unsafe_memcpy
from komira_buffer.byte_view import ByteView
from komira_parquet_codec.snappy import snappy_decompress


def main() raises:
    # -------------------------------------------------------------------------
    # Test 1: offset=2 pattern (e.g. "ab" repeated)
    # Uncompressed: "ababababababababab" (18 bytes)
    # Compressed (hand-built snappy format):
    #   varint(18)       = 0x12
    #   literal tag(3)   = (2<<2)|0 = 0x08, then bytes 'a','b','a'
    #   copy-2 tag(15,2) = tag=(14<<2)|2=0x3A, offset_lo=0x02, offset_hi=0x00
    # -------------------------------------------------------------------------
    var cbuf1 = alloc[UInt8](32)
    cbuf1[0] = 18   # varint uncompressed_len = 18
    cbuf1[1] = 0x08 # literal tag: len_minus_1=2 → 3 bytes
    cbuf1[2] = 0x61 # 'a'
    cbuf1[3] = 0x62 # 'b'
    cbuf1[4] = 0x61 # 'a'
    cbuf1[5] = 0x3A # copy-2: len=15, tag=(14<<2)|2=58=0x3A
    cbuf1[6] = 0x02 # offset low = 2
    cbuf1[7] = 0x00 # offset high = 0

    var dbuf1 = alloc[UInt8](18 + 64)  # +64 slop for fast path
    # Construct wildcard-origin ByteView at the test-harness boundary (same
    # pattern compression.mojo's FFI entry uses). snappy_decompress's public
    # API is ByteView[_], so origin-erased here.
    var n1 = snappy_decompress(
        ByteView[MutUntrackedOrigin](cbuf1, 8),
        ByteView[MutUntrackedOrigin](dbuf1, 18 + 64),
    )
    print("Test 1 (offset=2): produced", n1, "bytes (expected 18)")
    var ok1 = True
    for i in range(18):
        var expect: UInt8 = 0x61 if i % 2 == 0 else 0x62  # alternating a,b
        if dbuf1[i] != expect:
            print("  FAIL byte", i, "got", Int(dbuf1[i]), "expected", Int(expect))
            ok1 = False
    if ok1:
        print("  PASS")

    # -------------------------------------------------------------------------
    # Test 2: offset=3 pattern ("abc" repeated)
    # Uncompressed: "abcabcabcabcabcabc" (18 bytes)
    # Compressed:
    #   varint(18) = 0x12
    #   literal(3): tag=(2<<2)|0=0x08, 'a','b','c'
    #   copy-2(15, offset=3): tag=(14<<2)|2=0x3A, 0x03, 0x00
    # -------------------------------------------------------------------------
    var cbuf2 = alloc[UInt8](32)
    cbuf2[0] = 18
    cbuf2[1] = 0x08
    cbuf2[2] = 0x61  # 'a'
    cbuf2[3] = 0x62  # 'b'
    cbuf2[4] = 0x63  # 'c'
    cbuf2[5] = 0x3A  # copy-2(15, offset=3)
    cbuf2[6] = 0x03
    cbuf2[7] = 0x00

    var dbuf2 = alloc[UInt8](18 + 64)
    var n2 = snappy_decompress(
        ByteView[MutUntrackedOrigin](cbuf2, 8),
        ByteView[MutUntrackedOrigin](dbuf2, 18 + 64),
    )
    print("Test 2 (offset=3): produced", n2, "bytes (expected 18)")
    var ok2 = True
    for i in range(18):
        var r = i % 3
        var expect2 = UInt8(0x61) if r == 0 else (
            UInt8(0x62) if r == 1 else UInt8(0x63)
        )
        if dbuf2[i] != expect2:
            print("  FAIL byte", i, "got", Int(dbuf2[i]), "expected", Int(expect2))
            ok2 = False
    if ok2:
        print("  PASS")

    # -------------------------------------------------------------------------
    # Test 3: offset=5 pattern (longer short offset)
    # Uncompressed: "abcdeabcdeabcdeabcde" (20 bytes)
    # Compressed:
    #   varint(20) = 0x14
    #   literal(5): tag=(4<<2)|0=0x10, 'a','b','c','d','e'
    #   copy-2(15, offset=5): tag=(14<<2)|2=0x3A, 0x05, 0x00
    # -------------------------------------------------------------------------
    var cbuf3 = alloc[UInt8](32)
    cbuf3[0] = 20
    cbuf3[1] = 0x10   # literal: len_minus_1=4 → 5 bytes
    cbuf3[2] = 0x61   # 'a'
    cbuf3[3] = 0x62   # 'b'
    cbuf3[4] = 0x63   # 'c'
    cbuf3[5] = 0x64   # 'd'
    cbuf3[6] = 0x65   # 'e'
    cbuf3[7] = 0x3A   # copy-2(15, ...)
    cbuf3[8] = 0x05   # offset=5
    cbuf3[9] = 0x00

    var dbuf3 = alloc[UInt8](20 + 64)
    var n3 = snappy_decompress(
        ByteView[MutUntrackedOrigin](cbuf3, 10),
        ByteView[MutUntrackedOrigin](dbuf3, 20 + 64),
    )
    print("Test 3 (offset=5): produced", n3, "bytes (expected 20)")
    var ok3 = True
    var pat3 = "abcde"
    for i in range(20):
        var r3 = i % 5
        var expect3: UInt8
        if r3 == 0: expect3 = 0x61
        elif r3 == 1: expect3 = 0x62
        elif r3 == 2: expect3 = 0x63
        elif r3 == 3: expect3 = 0x64
        else: expect3 = 0x65
        if dbuf3[i] != expect3:
            print("  FAIL byte", i, "got", Int(dbuf3[i]), "expected", Int(expect3))
            ok3 = False
    if ok3:
        print("  PASS")

    # -------------------------------------------------------------------------
    # Test 4: Long literal (len_minus_1 >= 60), 1-byte extended length
    # Uncompressed: 100 bytes of 0xAB
    # Compressed:
    #   varint(100) = 0x64
    #   long-literal tag: len_minus_1 = 60, extra=1, val=99 (100-1)
    #     tag byte = (60 << 2) | 0 = 240 = 0xF0
    #     extra byte = 99 = 0x63
    #   then 100 bytes of 0xAB
    # -------------------------------------------------------------------------
    var cbuf4 = alloc[UInt8](200)
    cbuf4[0] = 100        # varint(100)
    cbuf4[1] = 0xF0       # long literal: len_minus_1=60
    cbuf4[2] = 99         # extra byte: 100-1=99 → literal_length=100
    for i in range(100):
        cbuf4[3 + i] = 0xAB

    var dbuf4 = alloc[UInt8](100 + 64)
    var n4 = snappy_decompress(
        ByteView[MutUntrackedOrigin](cbuf4, 103),
        ByteView[MutUntrackedOrigin](dbuf4, 100 + 64),
    )
    print("Test 4 (long literal, 100 bytes): produced", n4, "bytes (expected 100)")
    var ok4 = True
    for i in range(100):
        if dbuf4[i] != 0xAB:
            print("  FAIL byte", i, "got", Int(dbuf4[i]), "expected 0xAB")
            ok4 = False
    if ok4:
        print("  PASS")

    print("Done.")
