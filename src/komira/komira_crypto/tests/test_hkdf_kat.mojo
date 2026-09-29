# =============================================================================
# komira_crypto/tests/test_hkdf_kat.mojo — RFC 5869 Appendix A KAT
# =============================================================================
#
# Full RFC 5869 Appendix A KAT corpus for HKDF-SHA-256 (the SHA-1 cases
# A.4-A.6 are out of scope: Sha1 is not a `Hash`). Adds
# SHA-512 vectors via Python-reference cross-verification to exercise
# Hkdf[Sha512] generic instantiation.
#
# Appendix A.1 — basic test case (also covered by test_hkdf_smoke).
# Appendix A.2 — longer inputs/outputs (82-byte OKM = 3 SHA-256 blocks).
# Appendix A.3 — empty salt + empty info.
# =============================================================================

from std.testing import assert_equal

from komira_crypto import Hkdf, Sha256, Sha512
from komira_crypto import hex_lower


def _hex_to_bytes(hex_str: String) -> List[UInt8]:
    var out = List[UInt8]()
    var hex_bytes = hex_str.as_bytes()
    var n = len(hex_bytes)
    for i in range(0, n, 2):
        var hi = Int(hex_bytes[i])
        var lo = Int(hex_bytes[i + 1])
        var hi_v: Int
        if hi >= 0x30 and hi <= 0x39:
            hi_v = hi - 0x30
        else:
            hi_v = hi - 0x61 + 10
        var lo_v: Int
        if lo >= 0x30 and lo <= 0x39:
            lo_v = lo - 0x30
        else:
            lo_v = lo - 0x61 + 10
        out.append(UInt8((hi_v << 4) | lo_v))
    return out^


def _hex_of_inline32(d: Array[UInt8, 32]) -> String:
    var bytes = List[UInt8](capacity=32)
    for i in range(32):
        bytes.append(d[i])
    return hex_lower(Span[UInt8](bytes))


def _hex_of_inline64(d: Array[UInt8, 64]) -> String:
    var bytes = List[UInt8](capacity=64)
    for i in range(64):
        bytes.append(d[i])
    return hex_lower(Span[UInt8](bytes))


def _hex_of_list(l: List[UInt8]) -> String:
    return hex_lower(Span[UInt8](l))


# -----------------------------------------------------------------------------
# RFC 5869 Appendix A.1 — Test Case 1 (SHA-256, basic)
# Already covered by test_hkdf_smoke; included here for the dual-surface
# completeness assertion.
# -----------------------------------------------------------------------------


def test_rfc5869_a1_extract() raises:
    """A.1 extract: PRK = HMAC-SHA256(salt=0x00..0c, IKM=0x0b*22).
    Expected PRK = 077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5."""
    var ikm = _hex_to_bytes(
        String("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")
    )
    var salt = _hex_to_bytes(String("000102030405060708090a0b0c"))
    var prk = Hkdf[Sha256].extract(Span[UInt8](salt), Span[UInt8](ikm))
    assert_equal(
        _hex_of_inline32(prk),
        String(
            "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5"
        ),
    )


def test_rfc5869_a1_expand() raises:
    """A.1 expand: OKM = HKDF-Expand(PRK from A.1, info=0xf0..f9, L=42)."""
    var prk = _hex_to_bytes(
        String(
            "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5"
        )
    )
    var info = _hex_to_bytes(String("f0f1f2f3f4f5f6f7f8f9"))
    var okm = List[UInt8](capacity=42)
    for _ in range(42):
        okm.append(UInt8(0))
    Hkdf[Sha256].expand(
        Span[UInt8](prk), Span[UInt8](info), Span[UInt8](okm)
    )
    assert_equal(
        _hex_of_list(okm),
        String(
            "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"
        ),
    )


# -----------------------------------------------------------------------------
# RFC 5869 Appendix A.2 — Test Case 2 (SHA-256, longer inputs/outputs)
# 80-byte IKM, 80-byte salt, 80-byte info, 82-byte OKM (3 SHA-256 HashLen
# blocks → exercises the multi-block T(i) chaining and the truncated-T(N)
# tail-copy logic).
# -----------------------------------------------------------------------------


def test_rfc5869_a2_extract() raises:
    """A.2 extract — 80-byte IKM + 80-byte salt."""
    var ikm = _hex_to_bytes(
        String(
            "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f"
        )
    )
    var salt = _hex_to_bytes(
        String(
            "606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeaf"
        )
    )
    var prk = Hkdf[Sha256].extract(Span[UInt8](salt), Span[UInt8](ikm))
    assert_equal(
        _hex_of_inline32(prk),
        String(
            "06a6b88c5853361a06104c9ceb35b45cef760014904671014a193f40c15fc244"
        ),
    )


def test_rfc5869_a2_expand() raises:
    """A.2 expand — 80-byte info, L=82 (3 SHA-256 HashLen blocks)."""
    var prk = _hex_to_bytes(
        String(
            "06a6b88c5853361a06104c9ceb35b45cef760014904671014a193f40c15fc244"
        )
    )
    var info = _hex_to_bytes(
        String(
            "b0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"
        )
    )
    var okm = List[UInt8](capacity=82)
    for _ in range(82):
        okm.append(UInt8(0))
    Hkdf[Sha256].expand(
        Span[UInt8](prk), Span[UInt8](info), Span[UInt8](okm)
    )
    assert_equal(
        _hex_of_list(okm),
        String(
            "b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c59045a99cac7827271cb41c65e590e09da3275600c2f09b8367793a9aca3db71cc30c58179ec3e87c14c01d5c1f3434f1d87"
        ),
    )


# -----------------------------------------------------------------------------
# RFC 5869 Appendix A.3 — Test Case 3 (SHA-256, empty salt + empty info)
# Critical edge case for the empty-salt → 0^HashLen substitution path
# of HKDF-Extract.
# -----------------------------------------------------------------------------


def test_rfc5869_a3_extract() raises:
    """A.3 extract — IKM=0x0b*22, salt=empty, info=empty.
    Expected PRK = 19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04."""
    var ikm = _hex_to_bytes(
        String("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")
    )
    var salt = List[UInt8]()  # Empty salt
    var prk = Hkdf[Sha256].extract(Span[UInt8](salt), Span[UInt8](ikm))
    assert_equal(
        _hex_of_inline32(prk),
        String(
            "19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04"
        ),
    )


def test_rfc5869_a3_expand() raises:
    """A.3 expand — empty info, L=42."""
    var prk = _hex_to_bytes(
        String(
            "19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04"
        )
    )
    var info = List[UInt8]()  # Empty info
    var okm = List[UInt8](capacity=42)
    for _ in range(42):
        okm.append(UInt8(0))
    Hkdf[Sha256].expand(
        Span[UInt8](prk), Span[UInt8](info), Span[UInt8](okm)
    )
    assert_equal(
        _hex_of_list(okm),
        String(
            "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8"
        ),
    )


# -----------------------------------------------------------------------------
# SHA-512 instantiation — verifies Hkdf[Sha512] works (exercises the
# generic-over-H code path with a different H.OUTPUT_SIZE + BLOCK_SIZE).
# Reference values computed via Python (`hmac` + `hashlib`).
# -----------------------------------------------------------------------------


def test_hkdf_sha512_extract() raises:
    """HKDF-SHA-512 Extract — IKM=0x0b*22, salt=0x00..0c (same as A.1
    but with SHA-512). Verifies the H.OUTPUT_SIZE = 64 instantiation."""
    var ikm = _hex_to_bytes(
        String("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")
    )
    var salt = _hex_to_bytes(String("000102030405060708090a0b0c"))
    var prk = Hkdf[Sha512].extract(Span[UInt8](salt), Span[UInt8](ikm))
    # Reference: hmac.new(salt, ikm, hashlib.sha512).hexdigest()
    assert_equal(
        _hex_of_inline64(prk),
        String(
            "665799823737ded04a88e47e54a5890bb2c3d247c7a4254a8e61350723590a26c36238127d8661b88cf80ef802d57e2f7cebcf1e00e083848be19929c61b4237"
        ),
    )


def test_hkdf_sha512_expand() raises:
    """HKDF-SHA-512 Expand — same shape as A.1 expand, L=42."""
    var prk = _hex_to_bytes(
        String(
            "665799823737ded04a88e47e54a5890bb2c3d247c7a4254a8e61350723590a26c36238127d8661b88cf80ef802d57e2f7cebcf1e00e083848be19929c61b4237"
        )
    )
    var info = _hex_to_bytes(String("f0f1f2f3f4f5f6f7f8f9"))
    var okm = List[UInt8](capacity=42)
    for _ in range(42):
        okm.append(UInt8(0))
    Hkdf[Sha512].expand(
        Span[UInt8](prk), Span[UInt8](info), Span[UInt8](okm)
    )
    # Reference computed via Python.
    assert_equal(
        _hex_of_list(okm),
        String(
            "832390086cda71fb47625bb5ceb168e4c8e26a1a16ed34d9fc7fe92c1481579338da362cb8d9f925d7cb"
        ),
    )


def main() raises:
    test_rfc5869_a1_extract()
    test_rfc5869_a1_expand()
    test_rfc5869_a2_extract()
    test_rfc5869_a2_expand()
    test_rfc5869_a3_extract()
    test_rfc5869_a3_expand()
    test_hkdf_sha512_extract()
    test_hkdf_sha512_expand()
    print("OK")
