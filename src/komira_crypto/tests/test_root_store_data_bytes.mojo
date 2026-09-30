# =============================================================================
# komira_crypto/tests/test_root_store_data_bytes.mojo
# =============================================================================
#
# BYTE-IDENTITY GUARD for `komira_crypto/cert/root_store_data.mojo`.
#
# The 10 Mozilla CA roots in that file are spelled as ASCII hex literals
# rather than one `out.append(UInt8(0x..))` statement per byte (about
# 11,000 statements), because the statement form costs roughly 20x the
# compile time on every build of komira_crypto and everything downstream.
# The spelling is a BUILD concern living in a SECURITY-relevant file, so it
# needs a guard that the bytes cannot move — and a length check is not that
# guard. Two roots of the same length would pass one.
#
# Every SHA-256 below pins the exact DER of one root, over all of the
# roots' bytes. They also happen to be the published fingerprints of the roots
# themselves (ISRG Root X1 is the well-known 96:BC:EC:06:...:DF:08:C6), so
# they are independently checkable against Mozilla / the CAs.
#
# Three levels, deliberately:
#   (1) per-root SHA-256 over the decoded DER   — the bytes of each root;
#   (2) a whole-store SHA-256 over all 10 concatenated IN ORDER — catches a
#       reordering or a swap that (1) alone would let through;
#   (3) a hex round-trip, plus strictness tests on `_der_from_hex`, so the
#       decoder is pinned rather than trusted.
#
# WARNING: if you are here because this test went RED, the root store CHANGED.
# That is a trust decision, not a formatting one. Do not update these constants
# to make it green without saying who decided to change the trusted set.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_crypto.cert.root_store_data import (
    _root_isrg_root_x1_der,
    _root_isrg_root_x2_der,
    _root_digicert_global_root_ca_der,
    _root_digicert_global_root_g2_der,
    _root_amazon_root_ca_1_der,
    _root_usertrust_rsa_der,
    _root_usertrust_ecc_der,
    _root_gts_root_r1_der,
    _root_microsoft_rsa_2017_der,
    _root_globalsign_root_r6_der,
    _der_from_hex,
)
from komira_crypto.hex import hex_lower, hex_lower_array_32
from komira_crypto.sha256 import sha256


def _digest_of(der: List[UInt8]) -> String:
    """Lowercase hex SHA-256 of a DER buffer."""
    return hex_lower_array_32(sha256(Span(der)))


def _assert_root(
    name: String, der: List[UInt8], want_len: Int, want_sha256: String
) raises:
    """Pin ONE root: exact length, exact SHA-256 over every byte, and a hex
    round-trip through `_der_from_hex` (the decoder under test, which must not
    be the only thing vouching for itself)."""
    assert_equal(len(der), want_len, String("wrong DER length for ") + name)
    assert_equal(
        _digest_of(der),
        want_sha256,
        String("DER BYTES CHANGED for ") + name + String(" - see this file's header"),
    )
    # Round-trip: bytes -> hex -> bytes must be a fixed point.
    var round_tripped = _der_from_hex(hex_lower(Span(der)))
    assert_equal(len(round_tripped), len(der))
    for i in range(len(der)):
        assert_equal(
            round_tripped[i],
            der[i],
            String("hex round-trip diverged in ") + name,
        )


def test_every_root_is_byte_identical() raises:
    """All 10 roots match the digests taken from the pre-change file."""
    # ISRG Root X1
    _assert_root(
        String("ISRG Root X1"),
        _root_isrg_root_x1_der(),
        1391,
        String("96bcec06264976f37460779acf28c5a7cfe8a3c0aae11a8ffcee05c0bddf08c6"),
    )
    # ISRG Root X2
    _assert_root(
        String("ISRG Root X2"),
        _root_isrg_root_x2_der(),
        543,
        String("69729b8e15a86efc177a57afb7171dfc64add28c2fca8cf1507e34453ccb1470"),
    )
    # DigiCert Global Root CA
    _assert_root(
        String("DigiCert Global Root CA"),
        _root_digicert_global_root_ca_der(),
        947,
        String("4348a0e9444c78cb265e058d5e8944b4d84f9662bd26db257f8934a443c70161"),
    )
    # DigiCert Global Root G2
    _assert_root(
        String("DigiCert Global Root G2"),
        _root_digicert_global_root_g2_der(),
        914,
        String("cb3ccbb76031e5e0138f8dd39a23f9de47ffc35e43c1144cea27d46a5ab1cb5f"),
    )
    # Amazon Root CA 1
    _assert_root(
        String("Amazon Root CA 1"),
        _root_amazon_root_ca_1_der(),
        837,
        String("8ecde6884f3d87b1125ba31ac3fcb13d7016de7f57cc904fe1cb97c6ae98196e"),
    )
    # USERTrust RSA Certification Authority
    _assert_root(
        String("USERTrust RSA Certification Authority"),
        _root_usertrust_rsa_der(),
        1506,
        String("e793c9b02fd8aa13e21c31228accb08119643b749c898964b1746d46c3d4cbd2"),
    )
    # USERTrust ECC Certification Authority
    _assert_root(
        String("USERTrust ECC Certification Authority"),
        _root_usertrust_ecc_der(),
        659,
        String("4ff460d54b9c86dabfbcfc5712e0400d2bed3fbc4d4fbdaa86e06adcd2a9ad7a"),
    )
    # GTS Root R1
    _assert_root(
        String("GTS Root R1"),
        _root_gts_root_r1_der(),
        1371,
        String("d947432abde7b7fa90fc2e6b59101b1280e0e1c7e4e40fa3c6887fff57a7f4cf"),
    )
    # Microsoft RSA Root Certificate Authority 2017
    _assert_root(
        String("Microsoft RSA Root Certificate Authority 2017"),
        _root_microsoft_rsa_2017_der(),
        1452,
        String("c741f70f4b2a8d88bf2e71c14122ef53ef10eba0cfa5e64cfa20f418853073e0"),
    )
    # GlobalSign Root CA - R6
    _assert_root(
        String("GlobalSign Root CA - R6"),
        _root_globalsign_root_r6_der(),
        1415,
        String("2cabeafe37d06ca22aba7391c0033d25982952c453647349763a3ab5ad6ccf69"),
    )


def test_whole_store_digest_and_order() raises:
    """SHA-256 over all 10 DERs CONCATENATED IN LOAD ORDER.

    Per-root digests cannot see a reordering; this can. The order here is the
    order `root_store.mojo:mozilla_root_store()` appends them, so this also
    pins that the data file's function order still matches the store's.
    """
    var all_bytes = List[UInt8]()
    for b in _root_isrg_root_x1_der():
        all_bytes.append(b)
    for b in _root_isrg_root_x2_der():
        all_bytes.append(b)
    for b in _root_digicert_global_root_ca_der():
        all_bytes.append(b)
    for b in _root_digicert_global_root_g2_der():
        all_bytes.append(b)
    for b in _root_amazon_root_ca_1_der():
        all_bytes.append(b)
    for b in _root_usertrust_rsa_der():
        all_bytes.append(b)
    for b in _root_usertrust_ecc_der():
        all_bytes.append(b)
    for b in _root_gts_root_r1_der():
        all_bytes.append(b)
    for b in _root_microsoft_rsa_2017_der():
        all_bytes.append(b)
    for b in _root_globalsign_root_r6_der():
        all_bytes.append(b)

    assert_equal(len(all_bytes), 11035, "total root-store DER byte count moved")
    assert_equal(
        _digest_of(all_bytes),
        String("f88fe537224b5693286315b3513bf5c8f558dd967760e231345b36d67c91b5b9"),
        "WHOLE-STORE DIGEST CHANGED - a root's bytes or their ORDER moved",
    )


def test_der_from_hex_is_strict() raises:
    """The decoder must reject malformed input rather than shift bytes.

    A lenient decoder that silently skipped a bad character would shift every
    subsequent byte and yield a plausible-looking but WRONG certificate, which
    is the failure this whole file exists to make impossible.
    """
    # Whitespace (the line wrapping in the generated file) IS skipped.
    var wrapped = _der_from_hex("30 82\n05\t6b")
    assert_equal(len(wrapped), 4)
    assert_equal(wrapped[0], UInt8(0x30))
    assert_equal(wrapped[3], UInt8(0x6B))

    # A non-hex character raises.
    var raised_bad = False
    try:
        _ = _der_from_hex("30zz")
    except:
        raised_bad = True
    assert_true(raised_bad, "_der_from_hex accepted a non-hex character")

    # An odd digit count raises.
    var raised_odd = False
    try:
        _ = _der_from_hex("308")
    except:
        raised_odd = True
    assert_true(raised_odd, "_der_from_hex accepted an odd hex-digit count")


def main() raises:
    test_every_root_is_byte_identical()
    test_whole_store_digest_and_order()
    test_der_from_hex_is_strict()
    print("root_store_data byte-identity: 10 roots / 11035 bytes verified")
