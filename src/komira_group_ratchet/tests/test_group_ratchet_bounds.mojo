# =============================================================================
# tests/komira_group_ratchet/test_group_ratchet_bounds.mojo
#   The inbound skip bound is exact, on validly signed messages, and the sealed
#   key-share wire form is pinned by a known-answer vector.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_group_ratchet import (
    OutboundGroupSession,
    InboundGroupSession,
    SessionKeyShare,
    SealedKeyShare,
    open_session_key,
    MAX_INBOUND_SKIP,
    SESSION_ID_SIZE,
    RATCHET_SIZE,
    ED25519_PUB_SIZE,
)


def _ascii(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        out.append(bs[i])
    return out^


def test_skip_bound_is_exact_on_signed_messages() raises:
    """With the inbound session at base 0, a validly signed message at index
    MAX_INBOUND_SKIP decrypts and one at MAX_INBOUND_SKIP + 1 is refused. Both
    carry a genuine signature and tag, so only the bound can tell them apart."""
    var room = _ascii("room-bound")
    var out_sess = OutboundGroupSession(room)
    var inb = InboundGroupSession(out_sess.export_session_key(), room)
    var edge_index = Int(MAX_INBOUND_SKIP)

    var at_edge = out_sess.encrypt(_ascii("first"))
    for _ in range(edge_index - 1):
        _ = out_sess.encrypt(_ascii("skipped"))
    at_edge = out_sess.encrypt(_ascii("at the edge"))
    var past_edge = out_sess.encrypt(_ascii("past the edge"))
    assert_equal(Int(at_edge.index), edge_index)
    assert_equal(Int(past_edge.index), edge_index + 1)

    var dec = inb.decrypt(at_edge)
    assert_equal(len(dec), len(_ascii("at the edge")))

    var raised = False
    var msg = String("")
    try:
        _ = inb.decrypt(past_edge)
    except e:
        raised = True
        msg = String(e)
    assert_true(raised, "a signed message past the bound must be refused")
    assert_true("skip bound" in msg, "refused by the skip bound, not by another check: " + msg)


def _fixed(start: Int, n: Int) -> InlineArray[UInt8, 32]:
    var a = InlineArray[UInt8, 32](fill=UInt8(0))
    for i in range(n):
        a[i] = UInt8(start + i)
    return a^


def _nib(c: UInt8) -> UInt8:
    if c <= UInt8(0x39):
        return c - UInt8(0x30)
    return c - UInt8(0x61) + UInt8(10)


def _from_hex(s: String) -> List[UInt8]:
    var bs = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(bs) // 2):
        out.append((_nib(bs[2 * i]) << UInt8(4)) | _nib(bs[2 * i + 1]))
    return out^


def _fixed_share() -> SessionKeyShare:
    var ratchet = InlineArray[UInt8, RATCHET_SIZE](fill=UInt8(0))
    for i in range(RATCHET_SIZE):
        ratchet[i] = UInt8(0x40 + (i % 64))
    return SessionKeyShare(_fixed(0x00, 32), ratchet, UInt32(7), _fixed(0x80, 32))


# PINS WIRE COMPATIBILITY of the sealed key share. SEALED_KEYSHARE_KAT is the
# output of the current code for fixed inputs: recipient private key = bytes
# 0x01..0x20, ephemeral private key = bytes 0xA0..0xBF, share = _fixed_share().
# It is eph_pub(32) || ChaCha20-Poly1305(wrap_key, zero nonce, no AAD,
# serialized share) || tag(16), with wrap_key = HKDF-SHA-256(salt empty,
# IKM = X25519 shared secret, info = "komira-grp-keyshare-v1", L = 32).
# Opening it must give back the fixed share, so a change to the info string,
# the KDF, the AEAD, the nonce or the share layout fails here instead of
# silently making old sealed shares unreadable.
comptime SEALED_KEYSHARE_KAT = "605a725d2a4adfeeb1a29e17edd621c1b7593ee8cdbc44ac6c4ab6e2f805d23c816f67a5d2b583e9437218145d5f3667f2853750100a7d0144feabe7a440396bd51f5b73c139c2dc9462097f7693536636ebed0b3e5f216fb11ce82469101e1b6eb87a98fa218bf69ebf6a49396101583910791f5ddcb4181a98ef7d0886f698288db4696e304c60c3b7cd64646de99e69ccf1ca99a9fc123aefeec87569530f947656092064d8cb03b9a73aa0c3ead36d8ab9983939b0746d968bdce1aca71a515b455878301306a04ce86ae85b540d6a919259c43f56b9789598650fd0d2647535b4641b6fa1d250976d18f23362f7c0c756d4"


def test_sealed_key_share_known_answer() raises:
    """A sealed key share from the current code opens, with the fixed
    recipient key, to exactly the fixed share."""
    var sealed = SealedKeyShare.deserialize(_from_hex(SEALED_KEYSHARE_KAT))
    var opened = open_session_key(sealed, _fixed(0x01, 32))
    var want = _fixed_share()
    assert_equal(Int(opened.index), Int(want.index))
    for i in range(SESSION_ID_SIZE):
        assert_equal(Int(opened.session_id[i]), Int(want.session_id[i]))
    for i in range(RATCHET_SIZE):
        assert_equal(Int(opened.ratchet[i]), Int(want.ratchet[i]))
    for i in range(ED25519_PUB_SIZE):
        assert_equal(Int(opened.ed25519_pub[i]), Int(want.ed25519_pub[i]))


def main() raises:
    print("== test_group_ratchet_bounds ==")
    test_skip_bound_is_exact_on_signed_messages()
    test_sealed_key_share_known_answer()
    print("ALL group-ratchet bounds tests PASS")
