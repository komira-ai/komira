"""komira_group_ratchet — the Megolm-equivalent E2E group ratchet.

A STANDALONE, build-once library (dep closure: komira_crypto ONLY) consumed
by TWO call sites (the build-once thesis): (1) chat — each room is a
group; a member runs an outbound ratchet for its sends + inbound ratchets for
peers; (2) a multi-observer seal — one host = one sender, observers
= members, revoke = re-key. That use needs only a strict subset (outbound +
key-delivery half), confirming build-once.

WHAT IT IS: a per-sender OUTBOUND session = a 4-part 256-bit ratchet
advanced by an HMAC-SHA-256 tree at the 2^8 / 2^16 / 2^24 boundaries;
HKDF-SHA-256 derives the per-message AEAD key + nonce; messages are AEAD-sealed
with ChaCha20-Poly1305 (SUBSTITUTING Megolm's AES-256-CBC+HMAC — we own the
client) and Ed25519-signed. An INBOUND session is reconstructable from
{session_key, ratchet_index} and ratchets FORWARD only.

OUR IMPROVEMENT (reason for own-protocol): MLS-style POST-COMPROMISE
SECURITY — rotate_on_membership_change() starts a FRESH outbound session whose
key is delivered ONLY to current members, so a removed member (holding the old
session) cannot decrypt post-removal traffic.

THE PRIMITIVES IT BUILDS ON (all from komira_crypto):
  Hmac[Sha256]        — the ratchet advance tree (H_j = HMAC-SHA-256).
  Hkdf[Sha256]        — the per-message key schedule + the X25519 wrap key.
  ChaCha20Poly1305    — the message AEAD (the ONE Megolm substitution).
  ed25519_sign/verify — the per-message envelope signature.
  x25519 / base_mult  — the X25519-prekey group-key delivery.
  system_entropy      — CSPRNG for ratchet seeds / session ids / nonces.
  zeroize_inline_array — secret-zero-on-drop for every retired key / ratchet.

SAFETY GATE: ZERO UnsafePointer in any public signature;
ratchet / key / nonce buffers are InlineArray (gap6-clean, no byte-slab-of-
heap-field); zeroize on every retired session + key; constant-time tag compare
inside the AEAD.

The pure 4-part ratchet state machine + the HKDF key schedule.
"""

from .ratchet import (
    GroupRatchet,
    DerivedMessageKeys,
    RATCHET_SIZE,
    RATCHET_PART_SIZE,
    RATCHET_PARTS,
    AEAD_KEY_SIZE,
    NONCE_SEED_SIZE,
    KEY_SCHEDULE_INFO,
)

# The encrypted-message wire envelope + its codec + the signed region.
from .envelope import (
    MessageEnvelope,
    envelope_signed_region,
    encode_envelope,
    decode_envelope,
    ENVELOPE_VERSION,
    SESSION_ID_SIZE,
    ED25519_SIG_SIZE,
)

# The protocol layer: sessions, key-share delivery, rotation/PCS.
from .session import (
    OutboundGroupSession,
    InboundGroupSession,
    SessionKeyShare,
    SealedKeyShare,
    rotate_on_membership_change,
    seal_session_key,
    open_session_key,
    x25519_prekey_generate,
    ED25519_SEED_SIZE,
    ED25519_PUB_SIZE,
    X25519_KEY_SIZE,
    AEAD_TAG_SIZE,
    MAX_INBOUND_SKIP,
)
