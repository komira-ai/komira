# =============================================================================
# komira_crypto/tests/test_sha512_kat.mojo — boundary KAT
# =============================================================================
#
# KAT corpus for SHA-512. Each vector
# cross-verified against Python `hashlib.sha512(msg).hexdigest()`.
# See test_sha384_kat.mojo for the boundary-coverage rationale.
# =============================================================================

from std.testing import assert_equal

from komira_crypto import Sha512
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
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(UInt8(i & 0xFF))
    return out^


def _hex_of_digest(d: Array[UInt8, 64]) -> String:
    var bytes = List[UInt8](capacity=64)
    for i in range(64):
        bytes.append(d[i])
    return hex_lower(Span[UInt8](bytes))


def _assert_sha512(data: List[UInt8], expected_hex: String) raises:
    var h = Sha512()
    h.update(data)
    var dig = Array[UInt8, 64](fill=0)
    h.finalize_into(dig)
    assert_equal(_hex_of_digest(dig), expected_hex)


def test_sha512_kat_1byte_a() raises:
    _assert_sha512(
        _bytes_of(String("a")),
        String(
            "1f40fc92da241694750979ee6cf582f2d5d7d28e18335de05abc54d0560e0f5302860c652bf08d560252aa5e74210546f369fbbbce8c12cfc7957b2652fe9a75"
        ),
    )


def test_sha512_kat_1byte_zero() raises:
    var data = List[UInt8]()
    data.append(UInt8(0))
    _assert_sha512(
        data,
        String(
            "b8244d028981d693af7b456af8efa4cad63d282e19ff14942c246e50d9351d22704a802a71c3580b6370de4ceb293c324a8423342557d4e5c38438f0e36910ee"
        ),
    )


def test_sha512_kat_127bytes_a() raises:
    _assert_sha512(
        _rep(UInt8(0x61), 127),
        String(
            "828613968b501dc00a97e08c73b118aa8876c26b8aac93df128502ab360f91bab50a51e088769a5c1eff4782ace147dce3642554199876374291f5d921629502"
        ),
    )


def test_sha512_kat_128bytes_a() raises:
    """128 bytes 'a' — exactly one block. Two-block pad."""
    _assert_sha512(
        _rep(UInt8(0x61), 128),
        String(
            "b73d1929aa615934e61a871596b3f3b33359f42b8175602e89f7e06e5f658a243667807ed300314b95cacdd579f3e33abdfbe351909519a846d465c59582f321"
        ),
    )


def test_sha512_kat_129bytes_a() raises:
    _assert_sha512(
        _rep(UInt8(0x61), 129),
        String(
            "4f681e0bd53cda4b5a2041cc8a06f2eabde44fb16c951fbd5b87702f07aeab611565b19c47fde30587177ebb852e3971bbd8d3fd30da18d71037dfbd98420429"
        ),
    )


def test_sha512_kat_256bytes_a() raises:
    _assert_sha512(
        _rep(UInt8(0x61), 256),
        String(
            "6a9169eb662f136d87374070e8828b3e615a7eca32a89446e9225b02832709be095e635c824a2bb70213ba2ea0ababac0809827843992c851903b7ac0c136699"
        ),
    )


def test_sha512_kat_512bytes_a() raises:
    """Four blocks — full-block dispatch path of `update`."""
    _assert_sha512(
        _rep(UInt8(0x61), 512),
        String(
            "0210d27bcbe05c2156627c5f136ade1338ab98e06a4591a00b0bcaa61662a5931d0b3bd41a67b5c140627923f5f6307669eb508d8db38b2a8cd41aebd783394b"
        ),
    )


def test_sha512_kat_boundary_111() raises:
    """111 bytes — one byte short of padding boundary; pads to 128
    in one block."""
    _assert_sha512(
        _rep(UInt8(0x61), 111),
        String(
            "fa9121c7b32b9e01733d034cfc78cbf67f926c7ed83e82200ef86818196921760b4beff48404df811b953828274461673c68d04e297b0eb7b2b4d60fc6b566a2"
        ),
    )


def test_sha512_kat_boundary_112() raises:
    """112 bytes — exactly at padding boundary. blen=112 + 0x80 = 113
    > 112 → flush + pad second block. THE key boundary case."""
    _assert_sha512(
        _rep(UInt8(0x61), 112),
        String(
            "c01d080efd492776a1c43bd23dd99d0a2e626d481e16782e75d54c2503b5dc32bd05f0f1ba33e568b88fd2d970929b719ecbb152f58f130a407c8830604b70ca"
        ),
    )


def test_sha512_kat_boundary_113() raises:
    """113 bytes — one byte past boundary."""
    _assert_sha512(
        _rep(UInt8(0x61), 113),
        String(
            "55ddd8ac210a6e18ba1ee055af84c966e0dbff091c43580ae1be703bdb85da31acf6948cf5bd90c55a20e5450f22fb89bd8d0085e39f85a86cc46abbca75e24d"
        ),
    )


def test_sha512_kat_quickbrownfox() raises:
    _assert_sha512(
        _bytes_of(String("The quick brown fox jumps over the lazy dog")),
        String(
            "07e547d9586f6a73f73fbac0435ed76951218fb7d0c8d788a309d785436bbb642e93a252a954f23912547d1e8a3b5ed6e1bfd7097821233fa0538f3db854fee6"
        ),
    )


def test_sha512_kat_all_zero_64() raises:
    _assert_sha512(
        _rep(UInt8(0x00), 64),
        String(
            "7be9fda48f4179e611c698a73cff09faf72869431efee6eaad14de0cb44bbf66503f752b7a8eb17083355f3ce6eb7d2806f236b25af96a24e22b887405c20081"
        ),
    )


def test_sha512_kat_all_ff_64() raises:
    _assert_sha512(
        _rep(UInt8(0xFF), 64),
        String(
            "c835487ff6669f49f62757e572e7d3f9561fb6e111566ea086efa37923745966d6e7ed2220adf68321f89f818fcc8947fa87138896b3ac63b0504b3cdbd4f1e6"
        ),
    )


def test_sha512_kat_alternating_128() raises:
    _assert_sha512(
        _alternating_bytes(128),
        String(
            "1dffd5e3adb71d45d2245939665521ae001a317a03720a45732ba1900ca3b8351fc5c9b4ca513eba6f80bc7b1d1fdad4abd13491cb824d61b08d8c0e1561b3f7"
        ),
    )


def test_sha512_kat_boundary_240() raises:
    _assert_sha512(
        _rep(UInt8(0x61), 240),
        String(
            "4c296d90c61052a62ffb1dd196f1b7b09373b1f93e71836baebf89690546b7595684dbe9467a8e484fa0d1094272b4344a7c24f5fee8daedeb0bf549c985ab5f"
        ),
    )


def main() raises:
    test_sha512_kat_1byte_a()
    test_sha512_kat_1byte_zero()
    test_sha512_kat_127bytes_a()
    test_sha512_kat_128bytes_a()
    test_sha512_kat_129bytes_a()
    test_sha512_kat_256bytes_a()
    test_sha512_kat_512bytes_a()
    test_sha512_kat_boundary_111()
    test_sha512_kat_boundary_112()
    test_sha512_kat_boundary_113()
    test_sha512_kat_quickbrownfox()
    test_sha512_kat_all_zero_64()
    test_sha512_kat_all_ff_64()
    test_sha512_kat_alternating_128()
    test_sha512_kat_boundary_240()
    print("OK")
