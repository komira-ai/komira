# komira_group_ratchet

A Megolm-equivalent end-to-end group ratchet, built only on `komira_crypto`.

- `GroupRatchet` (`ratchet.mojo`): the 4-part 256-bit state, advanced by an
  HMAC-SHA-256 tree that reseeds at the 2^8, 2^16 and 2^24 boundaries, and
  the HKDF-SHA-256 key schedule that derives one message's AEAD key and nonce
  seed. State is `InlineArray` storage, never copied, zeroized on drop.
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
