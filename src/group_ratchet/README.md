# group_ratchet

A Megolm-equivalent end-to-end group ratchet, built only on `crypto`.

- `GroupRatchet` (`ratchet.mojo`): the 4-part 256-bit state, advanced by an
  HMAC-SHA-256 tree that reseeds at the 2^8, 2^16 and 2^24 boundaries, and
  the HKDF-SHA-256 key schedule that derives one message's AEAD key and nonce
  seed. State is `Array` storage, never copied, zeroized on drop.
- `MessageEnvelope` (`envelope.mojo`): the wire form of one message
  (version, session id, index, ciphertext and tag, Ed25519 signature) with
  `encode_envelope` and `decode_envelope`, and the one definition of the
  signed region both sides use.
- `OutboundGroupSession` and `InboundGroupSession` (`session.mojo`): the
  sender's ratchet (`encrypt` advances it, ChaCha20-Poly1305 seals, Ed25519
  signs) and the receiver's reconstruction from a `SessionKeyShare`, which
  ratchets forward only and refuses an index more than `MAX_INBOUND_SKIP`
  ahead. The room id is bound into the AEAD associated data.
- `seal_session_key` and `open_session_key`: X25519-sealed delivery of a
  `SessionKeyShare` to one recipient's prekey (`x25519_prekey_generate`); the
  all-zero shared secret is refused.
- `rotate_on_membership_change`: starts a fresh outbound session, so a
  removed member holding the old session cannot decrypt later messages. The
  caller delivers the new key to the current members only.

Replacing Megolm's AES-CBC plus HMAC with ChaCha20-Poly1305 changes the
derived key shape and the HKDF `info` (`komira-grp-aead-v1`), so this is not
wire-compatible with Matrix; the ratchet advance is the Megolm algorithm.
No public function takes or returns a pointer.

## Example

A sender delivers its session key to one recipient sealed to the recipient's
X25519 prekey, the recipient opens it and decrypts a message sent through the
wire codec, and after `rotate_on_membership_change` the old inbound session
refuses the new session's traffic.

```mojo module
from std.testing import assert_equal, assert_true
from group_ratchet import (
    OutboundGroupSession,
    InboundGroupSession,
    SealedKeyShare,
    decode_envelope,
    encode_envelope,
    rotate_on_membership_change,
    seal_session_key,
    open_session_key,
    x25519_prekey_generate,
)


def to_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        out.append(bs[i])
    return out^


def bytes_equal(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def main() raises:
    var room = to_bytes("!room0:example.test")
    var sender = OutboundGroupSession(room)

    var prekey = x25519_prekey_generate()
    var recipient_priv = prekey[0].copy()
    var recipient_pub = prekey[1].copy()
    var sealed = seal_session_key(sender.export_session_key(), recipient_pub)
    var sealed2 = SealedKeyShare.deserialize(sealed.serialize())
    var inbound = InboundGroupSession(open_session_key(sealed2, recipient_priv), room)

    var env = sender.encrypt(to_bytes("hello group"))
    assert_equal(sender.index(), UInt32(1))
    var received = inbound.decrypt(decode_envelope(encode_envelope(env)))
    assert_true(bytes_equal(received, to_bytes("hello group")))

    rotate_on_membership_change(sender)
    var after = sender.encrypt(to_bytes("after removal"))
    var refused = False
    try:
        _ = inbound.decrypt(after)
    except:
        refused = True
    assert_true(refused)
```
