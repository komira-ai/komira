# =============================================================================
# komira_group_ratchet/envelope.mojo — the encrypted-message wire envelope
# =============================================================================
#
# WHAT THIS IS: the on-the-wire shape of one encrypted group message. The
# OutboundGroupSession produces a MessageEnvelope; the InboundGroupSession
# consumes one. This file is the value type + its LE-framed codec (a storage
# substrate can hold it as an opaque value body).
#
# WIRE LAYOUT (LE framing — no JSON on the hot path):
#   [ ENVELOPE_VERSION: u8 ]
#   [ session_id: 32 bytes ]                  # identifies the sender's ratchet
#   [ index: u32 LE ]                         # the ratchet message index
#   [ ct_len: i64 LE ][ ciphertext_then_tag bytes... ]  # AEAD output (PT||16B tag)
#   [ sig: 64 bytes ]                         # Ed25519 over the signed-region
#
# THE SIGNED REGION (what Ed25519 covers): session_id || index_LE ||
# ciphertext_then_tag. The signature binds the sender's identity to THIS
# (session, index, ciphertext) tuple so a peer cannot splice another sender's
# ciphertext under this session/index. Defined ONCE here (envelope_signed_region)
# and reused by both sign (outbound) and verify (inbound) so the two cannot drift.
#
# THE AEAD AAD (what the tag binds, NOT in the signed region but in the AEAD):
#   session_id || index_LE || room_id. Built by the session layer (it knows
#   room_id); see session.mojo. Binding room_id in the AAD makes a cross-room
#   replay of an identical (session,index,ciphertext) fail the tag check even
#   if the signature were somehow reused.
#
# ENCAPSULATION + gap6 (safety gate): ZERO UnsafePointer in any signature;
# ZERO wildcard origins (Spans are origin_of(local)); ZERO unsafe_from_address;
# ZERO take_pointee. gap6 N/A: MessageEnvelope carries owned List[UInt8] +
# InlineArray fields and is a STACK value — never a byte-Slab element under a
# wildcard cast. The ciphertext is NOT secret (it is the wire form); no zeroize
# needed. def-based. Mojo 1.0.0b1.
# =============================================================================


comptime ENVELOPE_VERSION: UInt8 = 1
"""Wire-format version of the message envelope."""

comptime SESSION_ID_SIZE: Int = 32
"""Megolm session id is 32 random bytes (identifies the sender's ratchet)."""

comptime ED25519_SIG_SIZE: Int = 64
"""Ed25519 signature is 64 bytes (R || S)."""


# -----------------------------------------------------------------------------
# MessageEnvelope — one encrypted group message.
# -----------------------------------------------------------------------------


struct MessageEnvelope(Copyable, Movable, Deinitable):
    """One encrypted group-message envelope (the ciphertext body).

    Fields:
      session_id          — 32-byte id of the sender's outbound ratchet.
      index               — the ratchet message index this was encrypted at.
      ciphertext_then_tag — the ChaCha20-Poly1305 output: [ciphertext][16B tag].
                            Length = plaintext_len + 16. NOT secret (wire form).
      sig                 — 64-byte Ed25519 signature over the signed region.

    POD-of-owned (InlineArray + List[UInt8] + scalar) stack value (gap6 N/A).
    Copyable so the codec / test harness can pass it by value freely; nothing
    here is secret."""

    var session_id: InlineArray[UInt8, SESSION_ID_SIZE]
    var index: UInt32
    var ciphertext_then_tag: List[UInt8]
    var sig: InlineArray[UInt8, ED25519_SIG_SIZE]

    def __init__(
        out self,
        session_id: InlineArray[UInt8, SESSION_ID_SIZE],
        index: UInt32,
        var ciphertext_then_tag: List[UInt8],
        sig: InlineArray[UInt8, ED25519_SIG_SIZE],
    ):
        self.session_id = session_id.copy()
        self.index = index
        self.ciphertext_then_tag = ciphertext_then_tag^
        self.sig = sig.copy()


# -----------------------------------------------------------------------------
# The signed region — the byte sequence Ed25519 covers. ONE definition, reused
# by sign (outbound) + verify (inbound) so they cannot drift.
# -----------------------------------------------------------------------------


def envelope_signed_region(
    session_id: InlineArray[UInt8, SESSION_ID_SIZE],
    index: UInt32,
    ciphertext_then_tag: List[UInt8],
) -> List[UInt8]:
    """The byte sequence Ed25519 signs/verifies: session_id || index_LE ||
    ciphertext_then_tag. Binds the sender's signature to this exact (session,
    index, ciphertext) tuple. Defined once; both endpoints call it."""
    var out = List[UInt8]()
    out.reserve(SESSION_ID_SIZE + 4 + len(ciphertext_then_tag))
    for i in range(SESSION_ID_SIZE):
        out.append(session_id[i])
    var u = index
    for i in range(4):
        out.append(UInt8((u >> UInt32(8 * i)) & UInt32(0xFF)))
    for i in range(len(ciphertext_then_tag)):
        out.append(ciphertext_then_tag[i])
    return out^


# -----------------------------------------------------------------------------
# LE int framing (local re-derivation, a private helper, so the codec has no sibling dependency).
# -----------------------------------------------------------------------------


@always_inline
def _put_i64_le(mut out: List[UInt8], v: Int64):
    var u = UInt64(v)
    for i in range(8):
        out.append(UInt8((u >> UInt64(8 * i)) & UInt64(0xFF)))


@always_inline
def _get_i64_le(body: List[UInt8], off: Int) raises -> Int64:
    if off + 8 > len(body):
        raise Error("envelope: truncated i64 at offset " + String(off))
    var u = UInt64(0)
    for i in range(8):
        u |= UInt64(Int(body[off + i])) << UInt64(8 * i)
    return Int64(u)


@always_inline
def _put_u32_le(mut out: List[UInt8], v: UInt32):
    for i in range(4):
        out.append(UInt8((v >> UInt32(8 * i)) & UInt32(0xFF)))


@always_inline
def _get_u32_le(body: List[UInt8], off: Int) raises -> UInt32:
    if off + 4 > len(body):
        raise Error("envelope: truncated u32 at offset " + String(off))
    var u = UInt32(0)
    for i in range(4):
        u |= UInt32(Int(body[off + i])) << UInt32(8 * i)
    return u


# -----------------------------------------------------------------------------
# encode / decode — the envelope <-> wire bytes codec.
# -----------------------------------------------------------------------------


def encode_envelope(env: MessageEnvelope) -> List[UInt8]:
    """Serialize a MessageEnvelope to its LE-framed wire bytes."""
    var out = List[UInt8]()
    out.append(ENVELOPE_VERSION)
    for i in range(SESSION_ID_SIZE):
        out.append(env.session_id[i])
    _put_u32_le(out, env.index)
    _put_i64_le(out, Int64(len(env.ciphertext_then_tag)))
    for i in range(len(env.ciphertext_then_tag)):
        out.append(env.ciphertext_then_tag[i])
    for i in range(ED25519_SIG_SIZE):
        out.append(env.sig[i])
    return out^


def decode_envelope(body: List[UInt8]) raises -> MessageEnvelope:
    """Deserialize wire bytes into a MessageEnvelope. Fail-loud on a truncated /
    version-mismatched body (a torn envelope must never partially decode into a
    forged-index decrypt attempt)."""
    if len(body) < 1:
        raise Error("envelope: empty body")
    if body[0] != ENVELOPE_VERSION:
        raise Error(
            "envelope: version mismatch (got "
            + String(Int(body[0]))
            + ", want "
            + String(Int(ENVELOPE_VERSION))
            + ")"
        )
    var off = 1
    if off + SESSION_ID_SIZE > len(body):
        raise Error("envelope: truncated session_id")
    var session_id = InlineArray[UInt8, SESSION_ID_SIZE](fill=UInt8(0))
    for i in range(SESSION_ID_SIZE):
        session_id[i] = body[off + i]
    off += SESSION_ID_SIZE

    var index = _get_u32_le(body, off)
    off += 4

    var ct_len = Int(_get_i64_le(body, off))
    off += 8
    if ct_len < 0 or off + ct_len > len(body):
        raise Error("envelope: ciphertext length overruns body")
    var ciphertext_then_tag = List[UInt8]()
    ciphertext_then_tag.reserve(ct_len)
    for i in range(ct_len):
        ciphertext_then_tag.append(body[off + i])
    off += ct_len

    if off + ED25519_SIG_SIZE > len(body):
        raise Error("envelope: truncated signature")
    var sig = InlineArray[UInt8, ED25519_SIG_SIZE](fill=UInt8(0))
    for i in range(ED25519_SIG_SIZE):
        sig[i] = body[off + i]

    return MessageEnvelope(session_id, index, ciphertext_then_tag^, sig)
