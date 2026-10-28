# =============================================================================
# tests/komira_group_ratchet/test_group_ratchet_refusals.mojo
#   The wire codecs and constructors refuse malformed input, and the small
#   accessors agree with the values they report.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_group_ratchet import (
    GroupRatchet,
    RATCHET_SIZE,
    OutboundGroupSession,
    InboundGroupSession,
    SessionKeyShare,
    SealedKeyShare,
    MessageEnvelope,
    encode_envelope,
    decode_envelope,
    rotate_on_membership_change,
    seal_session_key,
    X25519_KEY_SIZE,
    AEAD_TAG_SIZE,
)


def _ascii(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        out.append(bs[i])
    return out^


def _prefix(body: List[UInt8], n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(n):
        out.append(body[i])
    return out^


def _sample_envelope() raises -> MessageEnvelope:
    var s = OutboundGroupSession(_ascii("room-codec"))
    return s.encrypt(_ascii("codec"))


def test_decode_refuses_every_truncation() raises:
    """Every strict prefix of a valid encoding is refused, whichever field the
    cut lands in (version, session id, index, length, ciphertext, signature);
    the whole encoding decodes to the same fields."""
    var env = _sample_envelope()
    var wire = encode_envelope(env)
    for n in range(len(wire)):
        var raised = False
        try:
            _ = decode_envelope(_prefix(wire, n))
        except:
            raised = True
        assert_true(raised, "a " + String(n) + "-byte prefix must be refused")
    var back = decode_envelope(wire)
    assert_equal(Int(back.index), Int(env.index))
    assert_equal(len(back.ciphertext_then_tag), len(env.ciphertext_then_tag))
    for i in range(len(env.sig)):
        assert_equal(Int(back.sig[i]), Int(env.sig[i]))
    for i in range(len(env.session_id)):
        assert_equal(Int(back.session_id[i]), Int(env.session_id[i]))


def test_decode_refuses_wrong_version() raises:
    """A body whose first byte is another version is refused."""
    var wire = encode_envelope(_sample_envelope())
    wire[0] = wire[0] + UInt8(1)
    var raised = False
    try:
        _ = decode_envelope(wire)
    except:
        raised = True
    assert_true(raised, "a different version byte must be refused")


def test_decode_refuses_bad_ciphertext_length() raises:
    """A negative length and a length past the body are both refused (the
    length field is i64 little-endian after version, session id and index)."""
    var off = 1 + 32 + 4
    var neg = encode_envelope(_sample_envelope())
    for i in range(8):
        neg[off + i] = UInt8(0xFF)
    var raised = False
    try:
        _ = decode_envelope(neg)
    except:
        raised = True
    assert_true(raised, "length -1 must be refused")

    var big = encode_envelope(_sample_envelope())
    big[off + 4] = UInt8(0x7F)
    raised = False
    try:
        _ = decode_envelope(big)
    except:
        raised = True
    assert_true(raised, "a length past the body must be refused")


def test_group_ratchet_seed_length() raises:
    """A 127-byte seed is refused; a 128-byte seed builds a ratchet at the
    given index."""
    var short = List[UInt8]()
    for i in range(RATCHET_SIZE - 1):
        short.append(UInt8(i))
    var raised = False
    try:
        _ = GroupRatchet(Span[UInt8, origin_of(short)](short), UInt32(0))
    except:
        raised = True
    assert_true(raised, "a 127-byte seed must be refused")
    short.append(UInt8(127))
    var ok = GroupRatchet(Span[UInt8, origin_of(short)](short), UInt32(7))
    assert_equal(Int(ok.index()), 7)


def test_key_share_wire_lengths() raises:
    """A SessionKeyShare round-trips and any other length is refused; a
    SealedKeyShare needs at least the ephemeral key and a tag."""
    var s = OutboundGroupSession(_ascii("room-share"))
    var share = s.export_session_key()
    var wire = share.serialize()
    var back = SessionKeyShare.deserialize(wire)
    assert_equal(Int(back.index), Int(share.index))
    for i in range(len(share.ratchet)):
        assert_equal(Int(back.ratchet[i]), Int(share.ratchet[i]))

    var raised = False
    try:
        _ = SessionKeyShare.deserialize(_prefix(wire, len(wire) - 1))
    except:
        raised = True
    assert_true(raised, "a short key share must be refused")
    var long = wire.copy()
    long.append(UInt8(0))
    raised = False
    try:
        _ = SessionKeyShare.deserialize(long)
    except:
        raised = True
    assert_true(raised, "a long key share must be refused")

    var sealed = List[UInt8]()
    for _ in range(X25519_KEY_SIZE + AEAD_TAG_SIZE - 1):
        sealed.append(UInt8(1))
    raised = False
    try:
        _ = SealedKeyShare.deserialize(sealed)
    except:
        raised = True
    assert_true(raised, "a sealed share below eph_pub + tag must be refused")
    sealed.append(UInt8(1))
    var parsed = SealedKeyShare.deserialize(sealed)
    assert_equal(len(parsed.ciphertext_then_tag), AEAD_TAG_SIZE)


def test_seal_to_all_zero_prekey_refused() raises:
    """A recipient prekey of all zero bytes (a small-order point) is refused:
    no key share is sealed to a shared secret an observer can compute."""
    var s = OutboundGroupSession(_ascii("room-zero"))
    var zero = InlineArray[UInt8, X25519_KEY_SIZE](fill=UInt8(0))
    var raised = False
    try:
        _ = seal_session_key(s.export_session_key(), zero)
    except:
        raised = True
    assert_true(raised, "sealing to the all-zero prekey must be refused")


def test_accessors_and_rotation_identity() raises:
    """The inbound session reports the outbound's id, the outbound reports the
    key it signs under, and rotation changes the session id."""
    var room = _ascii("room-ids")
    var out_sess = OutboundGroupSession(room)
    var share = out_sess.export_session_key()
    var inb = InboundGroupSession(share, room)
    var pub = out_sess.signing_pub()
    var before = out_sess.session_id()
    for i in range(32):
        assert_equal(Int(inb.session_id()[i]), Int(before[i]))
        assert_equal(Int(pub[i]), Int(share.ed25519_pub[i]))
    rotate_on_membership_change(out_sess)
    var after = out_sess.session_id()
    var same = True
    for i in range(32):
        if after[i] != before[i]:
            same = False
    assert_false(same, "rotation must start a session with a new id")


def test_decrypt_refuses_other_session_and_earlier_index() raises:
    """An envelope of another session, and one at an index before the share's
    base, are refused before any key work."""
    var room = _ascii("room-refuse")
    var a = OutboundGroupSession(room)
    var b = OutboundGroupSession(room)
    var early = a.encrypt(_ascii("early"))
    var late_share = a.export_session_key()
    var inb = InboundGroupSession(late_share, room)

    var raised = False
    try:
        _ = inb.decrypt(early)
    except:
        raised = True
    assert_true(raised, "an index before the base must be refused")

    var foreign = b.encrypt(_ascii("foreign"))
    raised = False
    try:
        _ = inb.decrypt(foreign)
    except:
        raised = True
    assert_true(raised, "another session's envelope must be refused")


def main() raises:
    print("== test_group_ratchet_refusals ==")
    test_decode_refuses_every_truncation()
    test_decode_refuses_wrong_version()
    test_decode_refuses_bad_ciphertext_length()
    test_group_ratchet_seed_length()
    test_key_share_wire_lengths()
    test_seal_to_all_zero_prekey_refused()
    test_accessors_and_rotation_identity()
    test_decrypt_refuses_other_session_and_earlier_index()
    print("ALL group-ratchet refusal tests PASS")
