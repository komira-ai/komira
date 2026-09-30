# =============================================================================
# komira_crypto/tests/test_sha384_kat.mojo — boundary KAT
# =============================================================================
#
# KAT corpus. Each vector is independently
# cross-verified against Python `hashlib.sha384(msg).hexdigest()` (the
# canonical reference impl using OpenSSL libcrypto under the hood).
#
# Boundary coverage:
#   * 1-byte / single-block (1, 127, 128, 129 bytes 'a')
#   * Multi-block (256, 257, 512 bytes 'a')
#   * Padding boundaries (111, 112, 113, 240 bytes — exercises the
#     "blen+1 > 112 → flush + new block + 16-byte length" path of
#     `_finalize_in_place`)
#   * Known cross-impl vectors (quick brown fox + variations)
#   * Edge value bytes (all-zero, all-0xFF, alternating)
#
# The full NIST CAVP corpus (SHA384ShortMsg.rsp + SHA384LongMsg.rsp +
# Monte.rsp) is in the test_cavp_sha384_* tests.
# =============================================================================

from std.testing import assert_equal

from komira_crypto import Sha384
from komira_crypto import hex_lower


def _bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        out.append(bs[i])
    return out^


def _rep(c: UInt8, n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for _ in range(n):
        out.append(c)
    return out^


def _alternating_bytes(n: Int) -> List[UInt8]:
    """Build a list of n bytes where byte[i] = i & 0xFF."""
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(UInt8(i & 0xFF))
    return out^


def _hex_of_digest(d: Array[UInt8, 48]) -> String:
    var bytes = List[UInt8](capacity=48)
    for i in range(48):
        bytes.append(d[i])
    return hex_lower(Span[UInt8](bytes))


def _assert_sha384(data: List[UInt8], expected_hex: String) raises:
    var h = Sha384()
    h.update(data)
    var dig = Array[UInt8, 48](fill=0)
    h.finalize_into(dig)
    assert_equal(_hex_of_digest(dig), expected_hex)


def test_sha384_kat_1byte_a() raises:
    _assert_sha384(
        _bytes_of(String("a")),
        String(
            "54a59b9f22b0b80880d8427e548b7c23abd873486e1f035dce9cd697e85175033caa88e6d57bc35efae0b5afd3145f31"
        ),
    )


def test_sha384_kat_1byte_zero() raises:
    var data = List[UInt8]()
    data.append(UInt8(0))
    _assert_sha384(
        data,
        String(
            "bec021b4f368e3069134e012c2b4307083d3a9bdd206e24e5f0d86e13d6636655933ec2b413465966817a9c208a11717"
        ),
    )


def test_sha384_kat_127bytes_a() raises:
    """127 bytes 'a' — one byte short of one block (128). Padding
    must add 0x80 then 0 bytes then 16-byte length; total 128 (one
    block compression total)."""
    _assert_sha384(
        _rep(UInt8(0x61), 127),
        String(
            "9bd06b1763c2cf7aef40e795dc65bc96d59c41b537f3ad72ebdefd485476b5717c1aeb37c327fe9c1831b12b9efd08ae"
        ),
    )


def test_sha384_kat_128bytes_a() raises:
    """128 bytes 'a' — exactly one block. Padding must flush the
    one-block buffer, then build a SECOND block holding 0x80 + zeros
    + 16-byte length."""
    _assert_sha384(
        _rep(UInt8(0x61), 128),
        String(
            "edb12730a366098b3b2beac75a3bef1b0969b15c48e2163c23d96994f8d1bef760c7e27f3c464d3829f56c0d53808b0b"
        ),
    )


def test_sha384_kat_129bytes_a() raises:
    """129 bytes 'a' — one byte into second block. Padding goes into
    second block after the one-byte tail."""
    _assert_sha384(
        _rep(UInt8(0x61), 129),
        String(
            "39b6f5a7b0e781dbc419f72e49b30eaac10f2c98c4403bc610da31067fd1b48f324138c8615d2b496d08d73d5e865326"
        ),
    )


def test_sha384_kat_256bytes_a() raises:
    """256 bytes 'a' — exactly two blocks."""
    _assert_sha384(
        _rep(UInt8(0x61), 256),
        String(
            "ee89d91a5f594f72052c561e5c2458280439eaa77cc1352e27893931c6d9ce5d869fb8a024358c460adc1af9f4fe5b4a"
        ),
    )


def test_sha384_kat_512bytes_a() raises:
    """512 bytes 'a' — exactly four blocks. Exercises the `while
    i + 128 <= n:` body of `update` for full-block dispatch."""
    _assert_sha384(
        _rep(UInt8(0x61), 512),
        String(
            "e685ba7acf4eedd1742f2a97c845e7825982d840623525e49140680fdde0f2631e5fce9dfcfb42ba7b27c9eb35a62b87"
        ),
    )


def test_sha384_kat_boundary_111() raises:
    """111 bytes — one byte short of the padding-boundary case
    (blen=111, blen+1=112 fits exactly). Pads to 128, no overflow."""
    _assert_sha384(
        _rep(UInt8(0x61), 111),
        String(
            "3c37955051cb5c3026f94d551d5b5e2ac38d572ae4e07172085fed81f8466b8f90dc23a8ffcdea0b8d8e58e8fdacc80a"
        ),
    )


def test_sha384_kat_boundary_112() raises:
    """112 bytes — exactly at the padding boundary. blen=112 + 0x80 =
    113; 113 > 112 → flush this block, build a second padding block.
    THIS is the path that's easy to get wrong."""
    _assert_sha384(
        _rep(UInt8(0x61), 112),
        String(
            "187d4e07cb306103c69967bf544d0dfbe9042577599c73c330abc0cb64c61236d5ed565ee19119d8c31779a38f791fcd"
        ),
    )


def test_sha384_kat_boundary_113() raises:
    """113 bytes — one byte past the padding boundary; same two-block
    pad path as 112 but with one more tail byte."""
    _assert_sha384(
        _rep(UInt8(0x61), 113),
        String(
            "1d6bed01626682961b50da078a6b1da707c1da0c8a0a3226f159235bd45ed724a0622fa6f39fd70007a6c72a5cda43ae"
        ),
    )


def test_sha384_kat_quickbrownfox() raises:
    """Classic cross-impl vector — pangram (43 bytes)."""
    _assert_sha384(
        _bytes_of(String("The quick brown fox jumps over the lazy dog")),
        String(
            "ca737f1014a48f4c0b6dd43cb177b0afd9e5169367544c494011e3317dbf9a509cb1e5dc1e85a941bbee3d7f2afbc9b1"
        ),
    )


def test_sha384_kat_quickbrownfox_with_dot() raises:
    """Quick brown fox with trailing dot (44 bytes; classic
    avalanche-effect demonstration vs Vector 11)."""
    _assert_sha384(
        _bytes_of(String("The quick brown fox jumps over the lazy dog.")),
        String(
            "ed892481d8272ca6df370bf706e4d7bc1b5739fa2177aae6c50e946678718fc67a7af2819a021c2fc34e91bdb63409d7"
        ),
    )


def test_sha384_kat_all_zero_64() raises:
    """64 bytes of 0x00. Edge value — all bytes zero."""
    _assert_sha384(
        _rep(UInt8(0x00), 64),
        String(
            "c516aa8d3b457c636c6826937099c0d23a13f2c3701a388b3c8fe4bc2073281b0c4462610369884c4ababa8e97b6debe"
        ),
    )


def test_sha384_kat_all_ff_64() raises:
    """64 bytes of 0xFF. Edge value — all bytes 0xFF."""
    _assert_sha384(
        _rep(UInt8(0xFF), 64),
        String(
            "223238f0bcaaca37515d1dfdf689408a479d84ecbd67248b033aa73eed08c68a0b76d3983211a4055823d157ae251fcc"
        ),
    )


def test_sha384_kat_alternating_128() raises:
    """128 bytes where byte[i] = i % 256 — exercises every byte value
    inside one block."""
    _assert_sha384(
        _alternating_bytes(128),
        String(
            "ca2385773319124534111a36d0581fc3f00815e907034b90cff9c3a861e126a741d5dfcff65a417b6d7296863ac0ec17"
        ),
    )


def test_sha384_kat_boundary_240() raises:
    """240 bytes — exercises the "two-block + tail" path: one full
    block (128) + 112-byte tail (which is exactly at the padding
    boundary again)."""
    _assert_sha384(
        _rep(UInt8(0x61), 240),
        String(
            "4d86957beab348a29180f02d02564ac1d32f5b4c217ece2b038f7c184f0cafc8c8e438eb82aa03796170e0a7ce8c0675"
        ),
    )


def main() raises:
    test_sha384_kat_1byte_a()
    test_sha384_kat_1byte_zero()
    test_sha384_kat_127bytes_a()
    test_sha384_kat_128bytes_a()
    test_sha384_kat_129bytes_a()
    test_sha384_kat_256bytes_a()
    test_sha384_kat_512bytes_a()
    test_sha384_kat_boundary_111()
    test_sha384_kat_boundary_112()
    test_sha384_kat_boundary_113()
    test_sha384_kat_quickbrownfox()
    test_sha384_kat_quickbrownfox_with_dot()
    test_sha384_kat_all_zero_64()
    test_sha384_kat_all_ff_64()
    test_sha384_kat_alternating_128()
    test_sha384_kat_boundary_240()
    print("OK")
