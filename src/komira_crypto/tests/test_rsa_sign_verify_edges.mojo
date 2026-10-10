# =============================================================================
# komira_crypto/tests/test_rsa_sign_verify_edges.mojo
#
# RSA paths no other welded test reaches:
#   * rsa_sha256_sign with a real RSA-2048 PKCS#8 key: its signature equals
#     the one Python's `cryptography` made for the same key and message
#     (PKCS#1 v1.5 is deterministic) and verifies under rsa_pkcs1_sha256_verify;
#   * rsa_sha256_sign refusing an Ed25519 and a P-256 PKCS#8 key (the parsed
#     key is not RSA) and a 488-bit RSA key (61 bytes cannot
#     hold the 62-byte SHA-256 DigestInfo encoding, so the final sign fails
#     after the size query);
#   * rsa_pss_verify over SHA-384 and SHA-512 (the MD_SHA384 / MD_SHA512
#     arms), accepting cryptography's signatures and refusing them with one
#     bit flipped;
#   * the argument refusals of rsa_pss_verify_ffi / rsa_pkcs1_sha256_verify_ffi
#     (unknown digest kind, digest length per kind, signature length, empty
#     modulus) and of rsa_public_key_from_bytes (modulus length);
#   * _check_private_key_info on an empty DER and on an algorithm OID that
#     runs past its AlgorithmIdentifier.
#
# Fixtures: the RSA-2048 key and its signatures over "komira rsa sign
# coverage" were made with Python `cryptography` (PKCS8 DER, PKCS1v15 and
# PSS with MGF1 of the same hash and salt = hash length). The 488-bit key is
# a hand-assembled PKCS#8 RSAPrivateKey (two 244-bit primes, e = 65537).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_crypto.rsa import rsa_sha256_sign, rsa_pkcs1_sha256_verify
from komira_crypto.rsa_pss import rsa_public_key_from_bytes, rsa_pss_verify
from komira_crypto.rsa_pem_key import _check_private_key_info
from komira_crypto.hash import Sha256, Sha384, Sha512
from komira_crypto.internal.asm.rsa_ffi import (
    MD_SHA256,
    MD_SHA384,
    MD_SHA512,
    rsa_pss_verify_ffi,
    rsa_pkcs1_sha256_verify_ffi,
)


def _hex(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8]()
    for i in range(0, len(b), 2):
        var hi = Int(b[i])
        var lo = Int(b[i + 1])
        hi = hi - 48 if hi < 58 else hi - 87
        lo = lo - 48 if lo < 58 else lo - 87
        out.append(UInt8(hi * 16 + lo))
    return out^


def _msg() -> List[UInt8]:
    var out = List[UInt8]()
    for c in String("komira rsa sign coverage").as_bytes():
        out.append(c)
    return out^


def _zeros(n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for _ in range(n):
        out.append(0)
    return out^


def _sign_err(key: List[UInt8]) -> String:
    var m = _msg()
    try:
        _ = rsa_sha256_sign(Span(key), Span(m))
    except e:
        return String(e)
    return String("no error")


def _rsa_pkcs8_hex() -> String:
    return (
        "308204be020100300d06092a864886f70d0101010500048204a8308204a40201000282010100c1d333f669ed6f66ff72"
        + "9bfc516139d3874963c6e34b9bc309fe83f5a0ebddb29711b7a42f31a975b1719e068da0773fe926b5428685e76d1905"
        + "23a544821e28dfd00c7c2da442f24737b07f265ef38e9550144a9ff0339f2424e7e007f9581a2278d20a7d8b57f84e90"
        + "2d486380912ed7869eac3bd300ebf330c1e3d9bf8838c3df008c7819b7466296ac4eb4c12cb3193e513dbdaed2b62364"
        + "1b0f69776ff6a2c5688eedf5153e6cf8e7b072f1b2568b84309cab3aa5dce9463fb5adc0230e5a9bcfa0906b89954d56"
        + "e930357cf73315c9f493bb8499f2c29dbf0c8efaf01acb2624b0e22f337f26f2a7e0e6afbb17accd88bfa59e1448b816"
        + "ea7a81fd19470203010001028201004a174e19b7cc47757bd877c02feb968b417fd0604aaab0541211f4a78468254b0b"
        + "6c7e628897d74b6215286f20dc6239500ab7e7423d158622b65035f0c63c792b750010c7f1ae95a69ba72033aec03394"
        + "e81399a321d2d9d69b34f7f29462153b702bfa4e9b61794daed7608088b8f6caf46edb2fd32cdb050f724e83023033b7"
        + "0793be4779cd265446272cdd27ecf5f65ef4812673897a86a9c78ec5f58927f64bb0eaabd336044a05927d2b6582170c"
        + "adefd3110fc521d727f3a22c5564cb3d6b87fc007e1d589060d457cfc29b1eb2c90740c61afc4505c3e8331b89665d1a"
        + "a23a615ab398ce1026210f15f7eb81990300d1445eb9d3524d45b58918696102818100fdf81e77f6e841d57671aae0cb"
        + "b7d60048657b330197d8a1bc9b9f41a74c95edaa5089d1724665c4ed200ca0ecba2ffef9405f3b75387b5b67d62a52a6"
        + "557b0694f42c1262f6a6e87bdaa2b76461471d2b79efc044f104048849a93ae7b96210be44381af5fc866e01290bcbad"
        + "c42a2f42dd7577cf65c99755f7fa4218cf288502818100c35ff7a4a348383ffb04a362d46d6b7c0cd794999a7bc67971"
        + "6852ad88924641b5ea64c934e8962321533aece247e283e47454d2cb21dcd3b3c7097872a2d912e888a42c5bde725d37"
        + "93b0744755b36c8cff6ef5be5086c410a060f50dc3ed3624ec801b92a1932d18aa2a1c6d20b03e53e668fe2087da58f8"
        + "2ab5d27b1a8a5b02818100caac5344511a104f95722877b49b44807d45df075962205311fcef1ea9b00885ddc0dffaf1"
        + "4314bc0eafe0e41b8689fee45266ad40628eaee732961bd6f9a8701c36af650cece14dee6910296245ef466c07a738bc"
        + "cbc9f503fe24bb09697bc4f8d1e02443e1fe35935f7a3654b993209c2fb72aa1ac0d30643ebccc3a9837310281806716"
        + "7800b2f72456fe08107dd1407afa557c5ab841bf159676b4690b8f883ef1e51eec570e47bb108640f8528d83088e3738"
        + "fa98cefdeb1af93d084e398e9ba35276e6c951202a8fed074c8fce23f62c4ca96aced7c07d9b6e7a712e5c39092d0c86"
        + "8d81fef8aa439d440c3c3b8887f61b26f43742caebf70ddadb5d57ff450902818100b7378fc6d462ab6e14fd929755e3"
        + "393a082214c28a88be5ef11a9bcfab877aa5aa4f9f9b24e25bcebacd83a665fed93cd01496952332a0b5c5c897cf9947"
        + "913af28778278c301be967707b83f230c84edf18e7d1f47b71b5a910afc4f955d710744a241908f685b4ead3d12a0aa5"
        + "5c77c5497bfc0d12b355f41a44afe8080cca"
    )


def _rsa_n_hex() -> String:
    return (
        "c1d333f669ed6f66ff729bfc516139d3874963c6e34b9bc309fe83f5a0ebddb29711b7a42f31a975b1719e068da0773f"
        + "e926b5428685e76d190523a544821e28dfd00c7c2da442f24737b07f265ef38e9550144a9ff0339f2424e7e007f9581a"
        + "2278d20a7d8b57f84e902d486380912ed7869eac3bd300ebf330c1e3d9bf8838c3df008c7819b7466296ac4eb4c12cb3"
        + "193e513dbdaed2b623641b0f69776ff6a2c5688eedf5153e6cf8e7b072f1b2568b84309cab3aa5dce9463fb5adc0230e"
        + "5a9bcfa0906b89954d56e930357cf73315c9f493bb8499f2c29dbf0c8efaf01acb2624b0e22f337f26f2a7e0e6afbb17"
        + "accd88bfa59e1448b816ea7a81fd1947"
    )


def _pkcs1_sig_hex() -> String:
    return (
        "6a1b01bfda419a140d75ed4c912eb92d6d761bc5eadd46288122725df445d356925d86ac8faf5fb64d3e2e90de5a4c85"
        + "c16fc427641a0e329537b381099ee7cd05bb3fea7786c82ec2969733c18f65493f6e1fcc4aafb28c0aa66ad9d0006192"
        + "b10e7c568592e0a5a707580057a608c057cb2cc13740160785d20d696ceae4b0f6c09e93492c55356aa80a25837b4d09"
        + "44d3132183dbbd3afeae18d10439e53a5efef6e7ea5e98755edb5e1a8a6a12fff8fc85be29e13c86da7bc6890c8d481d"
        + "952cc37d8d1d53022836de3462e2385ec0c41a1b38845265b464b7653c8f5dae3f4be4ad0c9b84f69f7e276110e9f4de"
        + "a23e21e72f6d7fb4e7e4e681199d8bcb"
    )


def _pss384_sig_hex() -> String:
    return (
        "999f4068a07044b152b77dda825696ced7432c09f187e2806fe5b17e236d5bde6630a7ed34acd8b1cf89723d9db49a17"
        + "38bf5655ab19c2a49990857157f40f2cad15d709bebd60e0284393344b560a04ca5298f90341d95f56925e5420d6ea4b"
        + "f88b85c93de0bfb3e604c918cb087f47724f2380a11a8b9691c8780d21f38de0501d7d8997fcedabaaec8c550a3fb48d"
        + "971065a4aa45770786c42694dd6802c9641e7dd65f7bdc10c665f54f22116b36a69529b95f8b1a7855c4341d7af03cea"
        + "ee148d189ab00d6ba57e23549077772dbb1e2f7ac542ca20b6c699614261b43ca0278916234424e3fdb3f7b9fdf5b4f1"
        + "1ce424c1e26a075f289f9681bdae1fed"
    )


def _pss512_sig_hex() -> String:
    return (
        "0aa831bf1c4035dcf7a70a390fb1dfabb9f961619473b443e5d095de5f5deeecefa6ce54b279cfdc45e985418c0e7a48"
        + "e457f7dd4788fe349ef22cc66129d9f97e3b04c5054b0dd2933ad3a903f6e4c19bce4bfb579cbfc38dd2908488bb72a1"
        + "a3f65c10eb032ae00e93f854935dbe872831eeeb0f1b847620cddac405f398f5336fe7256f76a5eb8776182aad3f5e12"
        + "17fc9c0f2935569563a039381123f6e407d3f45f075d18eeb2b40ae5c6061be3da21f999adedfa444150145e587373c2"
        + "4a53ec3c22bbfc0b6f1f93cb35d409a35384664475290b55277cd6b1d75e98184e7383edb2b60812f9f96dcaafb0f568"
        + "8f8a2035096ab9029e7aa56634b0e7d8"
    )


def _rsa488_pkcs8_hex() -> String:
    return (
        "30820147020100300d06092a864886f70d0101010500048201313082012d020100023e00de59f79b019eff1b698a1db4"
        + "29458384ed7ff5b34b18ef1b868bfa537e46d5fe80906592a98d72cf83e3894e7075dea1bd5556db7e6de2efc6d03fbd"
        + "650203010001023e00c05c02ead5bf30a20d6f107d814b0319e7c1d0d518bdec75dab3948fd0e9eb7559bfa0721e99a0"
        + "7c4f9796b2345ebac9b69ab08f5e16e59c7a996ce12d021f0fd29fb458190a75fa2f78e43aa6c00f40f80265d3b51306"
        + "42327c7cf9916b021f0e0d79f3fcaba8b5d4365e3fe324d1c0294474d3677d5115966700da99106f021f04e278fb2bd7"
        + "4f2b6cb90b112a2a20509535fb47843bfa4b8c5419aa5b4151021f078a57ac0222a22e9f26654066c3b50125a3a40463"
        + "fdac6aa6ffb24799e665021f01d0318c09ea09ee2f7b48000d3788f6703982404f74cfdb830406696b5096"
    )


# -----------------------------------------------------------------------------
# Signing
# -----------------------------------------------------------------------------


def test_sign_matches_an_independent_signer() raises:
    var key = _hex(_rsa_pkcs8_hex())
    var m = _msg()
    var sig = rsa_sha256_sign(Span(key), Span(m))
    var want = _hex(_pkcs1_sig_hex())
    assert_equal(len(sig), 256, "RSA-2048 signature length")
    for i in range(256):
        assert_equal(Int(sig[i]), Int(want[i]), "signature byte " + String(i))
    var n = _hex(_rsa_n_hex())
    assert_true(
        rsa_pkcs1_sha256_verify(Span(n), UInt64(65537), Span(m), Span(sig)),
        "the signature verifies",
    )


# A PKCS#8 PrivateKeyInfo holding a P-256 key (id-ecPublicKey, prime256v1)
# whose ECPrivateKey carries the scalar 0x0102...20 and no public key (AWS-LC
# computes it). Before the key-type check, rsa_sha256_sign returned a DER
# ECDSA-SHA256 signature for it.
def _p256_pkcs8_hex() -> String:
    return (
        "3041020100301306072a8648ce3d020106082a8648ce3d030107042730250201010420"
        + "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
    )


def test_sign_refuses_keys_it_cannot_use() raises:
    var ed = _hex(
        "302e020100300506032b657004220420000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    )
    var e = _sign_err(_hex(_p256_pkcs8_hex()))
    assert_true(e.find("the key is not an RSA key") >= 0, "P-256 key: " + e)
    e = _sign_err(ed)
    assert_true(e.find("the key is not an RSA key") >= 0, "Ed25519 key: " + e)
    e = _sign_err(_hex(_rsa488_pkcs8_hex()))
    assert_true(e.find("EVP_DigestSign final emit failed") >= 0, "488-bit key: " + e)


# -----------------------------------------------------------------------------
# PSS over SHA-384 / SHA-512
# -----------------------------------------------------------------------------


def test_pss_sha384_and_sha512() raises:
    var n = _hex(_rsa_n_hex())
    var pk = rsa_public_key_from_bytes[32](Span(n), UInt64(65537))
    var m = _msg()
    var s384 = _hex(_pss384_sig_hex())
    var s512 = _hex(_pss512_sig_hex())
    assert_true(rsa_pss_verify[32, Sha384](pk, Span(m), Span(s384), 48), "PSS SHA-384")
    assert_true(rsa_pss_verify[32, Sha512](pk, Span(m), Span(s512), 64), "PSS SHA-512")
    # Each signature is bound to its own hash.
    assert_false(rsa_pss_verify[32, Sha384](pk, Span(m), Span(s512), 48), "512 sig as 384")
    assert_false(rsa_pss_verify[32, Sha256](pk, Span(m), Span(s384), 32), "384 sig as 256")
    s384[255] ^= 1
    assert_false(rsa_pss_verify[32, Sha384](pk, Span(m), Span(s384), 48), "flipped bit")


def test_public_key_length_is_checked() raises:
    var short = _zeros(255)
    var e = String("no error")
    try:
        _ = rsa_public_key_from_bytes[32](Span(short), UInt64(65537))
    except err:
        e = String(err)
    assert_true(e.find("n_be length mismatch") >= 0, e)


# -----------------------------------------------------------------------------
# FFI argument refusals
# -----------------------------------------------------------------------------


def test_pss_ffi_argument_refusals() raises:
    var n = _hex(_rsa_n_hex())
    var m = _msg()
    var s384 = _hex(_pss384_sig_hex())
    var d48 = _zeros(48)
    var d32 = _zeros(32)
    var d64 = _zeros(64)
    var empty = List[UInt8]()
    var empty2 = List[UInt8]()
    var e = UInt64(65537)
    # The digest of the message, so the only thing wrong in each call is the
    # one argument it names.
    var h = Sha384()
    h.update(Span(m))
    h.finalize_into(Span(d48))
    assert_true(rsa_pss_verify_ffi(Span(n), e, Span(d48), MD_SHA384, Int32(48), Span(s384)), "baseline")
    assert_false(rsa_pss_verify_ffi(Span(n), e, Span(d48), Int32(3), Int32(48), Span(s384)), "unknown md")
    assert_false(rsa_pss_verify_ffi(Span(n), e, Span(d48), Int32(-1), Int32(48), Span(s384)), "md -1")
    assert_false(rsa_pss_verify_ffi(Span(n), e, Span(d48), MD_SHA256, Int32(48), Span(s384)), "48-byte digest as SHA-256")
    assert_false(rsa_pss_verify_ffi(Span(n), e, Span(d32), MD_SHA384, Int32(48), Span(s384)), "32-byte digest as SHA-384")
    assert_false(rsa_pss_verify_ffi(Span(n), e, Span(d32), MD_SHA512, Int32(48), Span(s384)), "32-byte digest as SHA-512")
    assert_false(rsa_pss_verify_ffi(Span(n), e, Span(d64), MD_SHA384, Int32(48), Span(s384)), "64-byte digest as SHA-384")
    var short_sig = _zeros(255)
    assert_false(rsa_pss_verify_ffi(Span(n), e, Span(d48), MD_SHA384, Int32(48), Span(short_sig)), "signature shorter than n")
    assert_false(rsa_pss_verify_ffi(Span(empty), e, Span(d48), MD_SHA384, Int32(48), Span(empty2)), "empty modulus")


def test_pkcs1_ffi_argument_refusals() raises:
    var n = _hex(_rsa_n_hex())
    var m = _msg()
    var sig = _hex(_pkcs1_sig_hex())
    var d = _zeros(32)
    var h = Sha256()
    h.update(Span(m))
    h.finalize_into(Span(d))
    var e = UInt64(65537)
    assert_true(rsa_pkcs1_sha256_verify_ffi(Span(n), e, Span(d), Span(sig)), "baseline")
    var d31 = _zeros(31)
    for i in range(31):
        d31[i] = d[i]
    assert_false(rsa_pkcs1_sha256_verify_ffi(Span(n), e, Span(d31), Span(sig)), "31-byte digest")
    var sig255 = _zeros(255)
    assert_false(rsa_pkcs1_sha256_verify_ffi(Span(n), e, Span(d), Span(sig255)), "signature shorter than n")
    var empty = List[UInt8]()
    var empty2 = List[UInt8]()
    assert_false(rsa_pkcs1_sha256_verify_ffi(Span(empty), e, Span(d), Span(empty2)), "empty modulus")


# -----------------------------------------------------------------------------
# PrivateKeyInfo envelope
# -----------------------------------------------------------------------------


def _envelope_err(der: List[UInt8]) -> String:
    try:
        _check_private_key_info(Span(der))
    except e:
        return String(e)
    return String("no error")


def test_private_key_info_envelope_edges() raises:
    var e = _envelope_err(List[UInt8]())
    assert_true(e.find("not a PKCS#8 PrivateKeyInfo: no DER") >= 0, "empty: " + e)
    # SEQUENCE { INTEGER 0, SEQUENCE(len 2) { OID(len 9 ... } , OCTET STRING }:
    # the OID's value runs past the 2-byte AlgorithmIdentifier.
    var der = _hex("3013020100300206092a864886f70d010101040100")
    e = _envelope_err(der)
    assert_true(e.find("no algorithm OBJECT IDENTIFIER") >= 0, "OID past its SEQUENCE: " + e)
    # The same bytes with a correct AlgorithmIdentifier length pass the envelope.
    var ok = _hex("3013020100300b06092a864886f70d010101040100")
    assert_equal(_envelope_err(ok), String("no error"), "well-formed envelope")


def main() raises:
    test_sign_matches_an_independent_signer()
    test_sign_refuses_keys_it_cannot_use()
    test_pss_sha384_and_sha512()
    test_public_key_length_is_checked()
    test_pss_ffi_argument_refusals()
    test_pkcs1_ffi_argument_refusals()
    test_private_key_info_envelope_edges()
    print("test_rsa_sign_verify_edges: 7 tests PASS")
