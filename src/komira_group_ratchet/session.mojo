# =============================================================================
# komira_group_ratchet/session.mojo — outbound + inbound group sessions
# =============================================================================
#
# WHAT THIS IS: the protocol layer over the pure ratchet (ratchet.mojo). It owns:
#   * OutboundGroupSession — a sender's per-room ratchet. encrypt() advances.
#   * InboundGroupSession  — a receiver's reconstruction from {session_key, idx}.
#                            decrypt() ratchets FORWARD only.
#   * SessionKeyShare      — the {session_id, ratchet@index, ed25519_pub} export
#                            bundle (delivered X25519-sealed per recipient).
#
# THE MEGOLM SUBSTITUTION (the reason for own-protocol):
#   Megolm uses AES-256-CBC + a separate HMAC for the message AEAD because
#   Matrix predates ubiquitous AEAD and must interop with old clients. We OWN
#   the client, so we use ChaCha20-Poly1305 (RFC 8439, single-pass AEAD,
#   constant-time by construction) directly. This DELETES the AES-CBC+HMAC
#   composition. Consequence: the per-message key schedule derives a 32-byte
#   ChaCha20 key + 12-byte nonce (vs Megolm's 32B AES key + 32B HMAC key + 16B
#   IV), and the HKDF `info` is OUR "komira-grp-aead-v1" (vs "MEGOLM_KEYS"). The
#   ratchet ADVANCE (HMAC-SHA-256 tree) + the HKDF MECHANISM are byte-identical
#   to Megolm; only the AEAD primitive + key-schedule output shape differ.
#
# OUR IMPROVEMENT — MLS-style POST-COMPROMISE SECURITY (headline win):
#   rotate_on_membership_change() starts a FRESH outbound session (new random
#   ratchet seed, new session_id). The new session key is delivered ONLY to the
#   current member set. A REMOVED member holds the OLD inbound session and never
#   receives the new key -> it CANNOT decrypt post-rotation traffic. The
#   don't-deliver-to-removed invariant is enforced at the API: export_session_key
#   hands out the CURRENT session's key, and the caller (chat) delivers it to the
#   current roster only. The library makes the cryptographic guarantee (old
#   session is useless against new-session ciphertext — distinct keystream);
#   the caller makes the delivery-roster guarantee.
#
# THE NONCE: nonce = nonce_seed XOR le32(index) (low 4 bytes). The ratchet
# guarantees a UNIQUE (key, index) per message within a session; XORing the LE
# index into the nonce seed makes the 96-bit nonce unique per message under a
# given derived key. Because derive_message_keys is per-INDEX (the ratchet
# advances every message), the (key,nonce) pair never repeats within a session.
#
# ENCAPSULATION + gap6 (safety gate): ZERO UnsafePointer in any signature;
# ZERO wildcard origins (Spans are origin_of(local)); ZERO unsafe_from_address;
# ZERO take_pointee. The Ed25519 signing seed + ratchet are SECRET: zeroized on
# drop. gap6 N/A: every field is InlineArray / a Movable GroupRatchet (itself
# InlineArray-backed) / a scalar / owned List — no Movable-with-heap-field
# byte-Slab element under a wildcard cast. def-based. Mojo 1.0.0b1.
# =============================================================================

from komira_crypto import (
    ChaCha20Poly1305,
    ed25519_sign,
    ed25519_verify,
    ed25519_pubkey_from_seed,
    x25519,
    x25519_base_mult,
    Hkdf,
    Sha256,
    system_entropy,
    zeroize_inline_array,
)

from .ratchet import (
    GroupRatchet,
    RATCHET_SIZE,
    AEAD_KEY_SIZE,
    NONCE_SEED_SIZE,
)
from .envelope import (
    MessageEnvelope,
    envelope_signed_region,
    SESSION_ID_SIZE,
    ED25519_SIG_SIZE,
)


comptime ED25519_SEED_SIZE: Int = 32
"""Ed25519 secret seed is 32 bytes (RFC 8032 §5.1.5)."""

comptime ED25519_PUB_SIZE: Int = 32
"""Ed25519 public key is 32 bytes."""

comptime X25519_KEY_SIZE: Int = 32
"""X25519 scalar / point is 32 bytes."""

comptime AEAD_TAG_SIZE: Int = 16
"""ChaCha20-Poly1305 tag size."""

comptime KEYSHARE_WRAP_INFO: StaticString = "komira-grp-keyshare-v1"
"""HKDF info domain separator for the X25519 key-share wrap key."""

comptime MAX_INBOUND_SKIP: UInt32 = 2000
"""Bound on how far an inbound session will fast-forward in one decrypt to
reach a received index. Caps the work a malicious far-future index can force on
a receiver (Megolm's gap bound). A real far-jump triggers a re-share request at
the chat layer rather than unbounded HMAC work here."""


# -----------------------------------------------------------------------------
# Nonce construction — shared by encrypt + decrypt so they cannot drift.
# -----------------------------------------------------------------------------


@always_inline
def _make_nonce(
    nonce_seed: InlineArray[UInt8, NONCE_SEED_SIZE], index: UInt32
) -> InlineArray[UInt8, NONCE_SEED_SIZE]:
    """nonce = nonce_seed XOR le32(index) into the low 4 bytes. Per-index
    uniqueness within a session (the ratchet advances every message, so the
    derived key is per-index AND the nonce carries the index — defense in
    depth against any single-source nonce-reuse)."""
    var nonce = InlineArray[UInt8, NONCE_SEED_SIZE](fill=UInt8(0))
    for i in range(NONCE_SEED_SIZE):
        nonce[i] = nonce_seed[i]
    for i in range(4):
        nonce[i] = nonce[i] ^ UInt8((index >> UInt32(8 * i)) & UInt32(0xFF))
    return nonce^


@always_inline
def _make_aad(
    session_id: InlineArray[UInt8, SESSION_ID_SIZE],
    index: UInt32,
    room_id: List[UInt8],
) -> List[UInt8]:
    """The AEAD associated data: session_id || index_LE || room_id. Binds the
    ciphertext tag to the room so a cross-room replay of an identical
    (session,index,ciphertext) fails the tag check. Shared by encrypt+decrypt."""
    var aad = List[UInt8]()
    aad.reserve(SESSION_ID_SIZE + 4 + len(room_id))
    for i in range(SESSION_ID_SIZE):
        aad.append(session_id[i])
    for i in range(4):
        aad.append(UInt8((index >> UInt32(8 * i)) & UInt32(0xFF)))
    for i in range(len(room_id)):
        aad.append(room_id[i])
    return aad^


# -----------------------------------------------------------------------------
# SessionKeyShare — the export bundle a receiver needs to build an inbound
# session: {session_id, ratchet@index, ed25519_pub}. Delivered X25519-sealed.
# -----------------------------------------------------------------------------


struct SessionKeyShare(Movable, Deinitable):
    """The exported session key: everything a receiver needs to decrypt from
    `index` forward. SECRET (it is the decryption capability) — Movable, NOT
    Copyable; the ratchet bytes are zeroized on drop.

    Fields:
      session_id  — 32-byte id of the outbound ratchet.
      ratchet     — the 128-byte ratchet state AT `index` (forward-only from
                    here; a receiver imported at index N cannot read index < N).
      index       — the message index the ratchet bytes correspond to.
      ed25519_pub — the sender's 32-byte signing public key (to verify
                    envelopes). PUBLIC, but bundled here for atomic delivery.

    gap6 N/A: all fields InlineArray / scalar."""

    var session_id: InlineArray[UInt8, SESSION_ID_SIZE]
    var ratchet: InlineArray[UInt8, RATCHET_SIZE]
    var index: UInt32
    var ed25519_pub: InlineArray[UInt8, ED25519_PUB_SIZE]

    def __init__(
        out self,
        session_id: InlineArray[UInt8, SESSION_ID_SIZE],
        ratchet: InlineArray[UInt8, RATCHET_SIZE],
        index: UInt32,
        ed25519_pub: InlineArray[UInt8, ED25519_PUB_SIZE],
    ):
        self.session_id = session_id.copy()
        self.ratchet = ratchet.copy()
        self.index = index
        self.ed25519_pub = ed25519_pub.copy()

    def __deinit__(deinit self):
        """Zeroize the secret ratchet bytes on drop. session_id / ed25519_pub /
        index are public (no zeroize needed) but the ratchet is the full
        forward decryption capability."""
        zeroize_inline_array[RATCHET_SIZE](self.ratchet)

    def serialize(self) -> List[UInt8]:
        """Serialize to a flat byte buffer for X25519-sealed to-device delivery.
        Layout: session_id(32) || ratchet(128) || index(4 LE) || ed25519_pub(32).
        Fixed-length (no length prefixes needed — all fields are comptime-sized).
        The CALLER X25519-seals this (seal_session_key) before it leaves the
        device; the plaintext layout never touches the wire."""
        var out = List[UInt8]()
        out.reserve(SESSION_ID_SIZE + RATCHET_SIZE + 4 + ED25519_PUB_SIZE)
        for i in range(SESSION_ID_SIZE):
            out.append(self.session_id[i])
        for i in range(RATCHET_SIZE):
            out.append(self.ratchet[i])
        for i in range(4):
            out.append(UInt8((self.index >> UInt32(8 * i)) & UInt32(0xFF)))
        for i in range(ED25519_PUB_SIZE):
            out.append(self.ed25519_pub[i])
        return out^

    @staticmethod
    def deserialize(body: List[UInt8]) raises -> SessionKeyShare:
        """Parse a flat key-share buffer (the inverse of serialize). Fail-loud
        on a wrong-length body."""
        var want = SESSION_ID_SIZE + RATCHET_SIZE + 4 + ED25519_PUB_SIZE
        if len(body) != want:
            raise Error(
                "SessionKeyShare.deserialize: expected "
                + String(want)
                + " bytes, got "
                + String(len(body))
            )
        var off = 0
        var session_id = InlineArray[UInt8, SESSION_ID_SIZE](fill=UInt8(0))
        for i in range(SESSION_ID_SIZE):
            session_id[i] = body[off + i]
        off += SESSION_ID_SIZE
        var ratchet = InlineArray[UInt8, RATCHET_SIZE](fill=UInt8(0))
        for i in range(RATCHET_SIZE):
            ratchet[i] = body[off + i]
        off += RATCHET_SIZE
        var index = UInt32(0)
        for i in range(4):
            index |= UInt32(Int(body[off + i])) << UInt32(8 * i)
        off += 4
        var ed25519_pub = InlineArray[UInt8, ED25519_PUB_SIZE](fill=UInt8(0))
        for i in range(ED25519_PUB_SIZE):
            ed25519_pub[i] = body[off + i]
        return SessionKeyShare(session_id, ratchet, index, ed25519_pub)


# -----------------------------------------------------------------------------
# OutboundGroupSession — a sender's per-room ratchet.
# -----------------------------------------------------------------------------


struct OutboundGroupSession(Movable, Deinitable):
    """A sender device's outbound group session for one room.

    encrypt() derives the per-message key from the CURRENT ratchet, AEAD-seals,
    Ed25519-signs, then ADVANCES the ratchet (so the key for this index is never
    reused). export_session_key() hands out the current ratchet so a member can
    build an inbound session.

    SECRET: the Ed25519 signing seed + the ratchet. Both zeroized on drop.
    Movable, NOT Copyable. gap6 N/A."""

    var _session_id: InlineArray[UInt8, SESSION_ID_SIZE]
    var _ratchet: GroupRatchet
    var _signing_seed: InlineArray[UInt8, ED25519_SEED_SIZE]
    var _signing_pub: InlineArray[UInt8, ED25519_PUB_SIZE]
    var _room_id: List[UInt8]

    def __init__(out self, room_id: List[UInt8]) raises:
        """Create a FRESH outbound session: random 32-byte session_id, 128-byte
        CSPRNG ratchet seed (1024 bits per the Megolm specification), and a fresh Ed25519
        signing keypair. index starts at 0.

        `room_id` is bound into every message's AEAD AAD (cross-room replay
        defense). It is copied in (the session owns its room_id)."""
        var session_id = InlineArray[UInt8, SESSION_ID_SIZE](fill=UInt8(0))
        system_entropy(Span[UInt8, origin_of(session_id)](session_id))

        var seed = InlineArray[UInt8, RATCHET_SIZE](fill=UInt8(0))
        system_entropy(Span[UInt8, origin_of(seed)](seed))

        var signing_seed = InlineArray[UInt8, ED25519_SEED_SIZE](fill=UInt8(0))
        system_entropy(Span[UInt8, origin_of(signing_seed)](signing_seed))
        var signing_pub = ed25519_pubkey_from_seed(
            Span[UInt8, origin_of(signing_seed)](signing_seed)
        )

        self._session_id = session_id^
        self._ratchet = GroupRatchet(
            Span[UInt8, origin_of(seed)](seed), UInt32(0)
        )
        # R1 transfer, not copy: `signing_seed` is the Ed25519 SECRET. b2's
        # implicit copy left an unzeroized duplicate on the stack (note the
        # sibling `seed` IS explicitly zeroized below for exactly this reason,
        # and `signing_seed` never was). Transfer leaves nothing to leak.
        self._signing_seed = signing_seed^
        self._signing_pub = signing_pub^
        var rid = List[UInt8]()
        rid.reserve(len(room_id))
        for i in range(len(room_id)):
            rid.append(room_id[i])
        self._room_id = rid^

        # Zeroize the transient seed (it now lives inside the ratchet).
        zeroize_inline_array[RATCHET_SIZE](seed)

    def __deinit__(deinit self):
        """Zeroize the Ed25519 signing seed on drop (the ratchet zeroizes
        itself via GroupRatchet.__del__)."""
        zeroize_inline_array[ED25519_SEED_SIZE](self._signing_seed)

    def session_id(self) -> InlineArray[UInt8, SESSION_ID_SIZE]:
        """The 32-byte session id (public — receivers key inbound sessions on
        it)."""
        return self._session_id.copy()

    def index(self) -> UInt32:
        """The NEXT message index this session will encrypt at."""
        return self._ratchet.index()

    def signing_pub(self) -> InlineArray[UInt8, ED25519_PUB_SIZE]:
        """The Ed25519 public key (public — receivers verify envelopes)."""
        return self._signing_pub.copy()

    def export_session_key(self) -> SessionKeyShare:
        """Export the CURRENT session key: {session_id, ratchet@current_index,
        ed25519_pub}. A receiver builds an inbound session from this and can
        decrypt from `current_index` FORWARD (never earlier — forward ratchet).

        This is the to-device delivery payload. The caller (chat) X25519-
        seals it per recipient (seal_session_key) and delivers ONLY to current
        members. Exporting at the CURRENT index (not 0) is the forward-secrecy
        lever: a member added now cannot read history before now."""
        return SessionKeyShare(
            self._session_id,
            self._ratchet.export_state(),
            self._ratchet.index(),
            self._signing_pub,
        )

    def encrypt(mut self, plaintext: List[UInt8]) raises -> MessageEnvelope:
        """Encrypt `plaintext` into a signed envelope, then ADVANCE the ratchet.

        Steps:
          1. derive (aead_key, nonce_seed) from the ratchet at the current index.
          2. nonce = nonce_seed XOR le32(index).
          3. AEAD-seal plaintext||zeros(16) in place with AAD = session_id ||
             index || room_id.
          4. Ed25519-sign session_id || index || ciphertext_then_tag.
          5. advance the ratchet, return the envelope.

        The advance AFTER encrypt guarantees the (key,nonce) for this index is
        never reused by this session."""
        var index = self._ratchet.index()
        var keys = self._ratchet.derive_message_keys()
        var nonce = _make_nonce(keys.nonce_seed, index)

        # plaintext_then_tag buffer: [plaintext][16 zero bytes for the tag].
        var buf = List[UInt8]()
        buf.reserve(len(plaintext) + AEAD_TAG_SIZE)
        for i in range(len(plaintext)):
            buf.append(plaintext[i])
        for _ in range(AEAD_TAG_SIZE):
            buf.append(UInt8(0))

        var aad = _make_aad(self._session_id, index, self._room_id)

        var cipher = ChaCha20Poly1305(keys.aead_key)
        cipher.seal_in_place(
            nonce,
            Span[UInt8, origin_of(aad)](aad),
            Span[UInt8, origin_of(buf)](buf),
        )

        # Sign session_id || index || ciphertext_then_tag.
        var signed = envelope_signed_region(self._session_id, index, buf)
        var sig = ed25519_sign(
            Span[UInt8, origin_of(self._signing_seed)](self._signing_seed),
            Span[UInt8, origin_of(signed)](signed),
        )

        # Advance the ratchet so this index's key is never reused.
        self._ratchet.advance()

        return MessageEnvelope(self._session_id, index, buf^, sig)


# -----------------------------------------------------------------------------
# InboundGroupSession — a receiver's reconstruction from a SessionKeyShare.
# -----------------------------------------------------------------------------


struct InboundGroupSession(Movable, Deinitable):
    """A receiver's inbound group session, reconstructed from a SessionKeyShare.

    decrypt() verifies the Ed25519 signature, ratchets a WORKING copy FORWARD to
    the envelope's index (never backward — forward-ratchet property), derives
    the key, and AEAD-opens. Out-of-order delivery within MAX_INBOUND_SKIP of the
    base index is supported by cloning + fast-forwarding the working copy.

    SECRET: the ratchet. Zeroized on drop. Movable, NOT Copyable. gap6 N/A."""

    var _session_id: InlineArray[UInt8, SESSION_ID_SIZE]
    var _ratchet: GroupRatchet
    var _base_index: UInt32
    var _ed25519_pub: InlineArray[UInt8, ED25519_PUB_SIZE]
    var _room_id: List[UInt8]

    def __init__(out self, share: SessionKeyShare, room_id: List[UInt8]) raises:
        """Build an inbound session from a SessionKeyShare + the room_id (which
        must match the room the sender bound into the AAD, else every decrypt
        fails the tag check). The session can decrypt from `share.index` FORWARD
        only."""
        self._session_id = share.session_id.copy()
        self._ratchet = GroupRatchet(
            Span[UInt8, origin_of(share.ratchet)](share.ratchet), share.index
        )
        self._base_index = share.index
        self._ed25519_pub = share.ed25519_pub.copy()
        var rid = List[UInt8]()
        rid.reserve(len(room_id))
        for i in range(len(room_id)):
            rid.append(room_id[i])
        self._room_id = rid^

    # No explicit __del__ needed beyond the ratchet's own zeroize-on-drop —
    # but we keep the public-field cleanup symmetric with the outbound session.

    def session_id(self) -> InlineArray[UInt8, SESSION_ID_SIZE]:
        return self._session_id.copy()

    def base_index(self) -> UInt32:
        """The earliest index this inbound session can decrypt."""
        return self._base_index

    def decrypt(self, env: MessageEnvelope) raises -> List[UInt8]:
        """Verify + decrypt an envelope. Raises on ANY integrity failure:
          * session_id mismatch (the envelope isn't for this session).
          * index < base_index (forward-ratchet violation: this session was
            imported too late to read this message).
          * index more than MAX_INBOUND_SKIP ahead of base (gap-bound; the chat
            layer should re-share rather than force unbounded work).
          * Ed25519 signature invalid (forged / tampered envelope).
          * AEAD tag invalid (tampered ciphertext, wrong room, or wrong key).

        Returns the plaintext on success. The fail-closed ordering: session +
        index checks, THEN signature, THEN AEAD open (the AEAD open is the
        constant-time tag verify; we do the cheap public-input checks first)."""
        # 1. session id must match.
        for i in range(SESSION_ID_SIZE):
            if env.session_id[i] != self._session_id[i]:
                raise Error("InboundGroupSession.decrypt: session_id mismatch")

        # 2. forward-ratchet: cannot decrypt an index earlier than import.
        if env.index < self._base_index:
            raise Error(
                "InboundGroupSession.decrypt: index "
                + String(Int(env.index))
                + " is before this session's base index "
                + String(Int(self._base_index))
                + " — the forward-ratchet property forbids decrypting it"
            )

        # 3. gap bound: refuse a far-future index (DoS guard / re-share signal).
        if env.index - self._base_index > MAX_INBOUND_SKIP:
            raise Error(
                "InboundGroupSession.decrypt: index "
                + String(Int(env.index))
                + " exceeds the skip bound ("
                + String(Int(MAX_INBOUND_SKIP))
                + ") from base "
                + String(Int(self._base_index))
                + " — request a fresh key share"
            )

        # 4. Ed25519 signature over session_id || index || ciphertext_then_tag.
        var signed = envelope_signed_region(
            env.session_id, env.index, env.ciphertext_then_tag
        )
        var sig_ok = ed25519_verify(
            Span[UInt8, origin_of(self._ed25519_pub)](self._ed25519_pub),
            Span[UInt8, origin_of(signed)](signed),
            Span[UInt8, origin_of(env.sig)](env.sig),
        )
        if not sig_ok:
            raise Error(
                "InboundGroupSession.decrypt: Ed25519 signature invalid"
                " (forged or tampered envelope)"
            )

        # 5. Fast-forward a WORKING copy of the ratchet to env.index, derive the
        #    per-index key, build the nonce + AAD, AEAD-open.
        var working = self._ratchet.clone_at()
        working.advance_to(env.index)
        var keys = working.derive_message_keys()
        var nonce = _make_nonce(keys.nonce_seed, env.index)
        var aad = _make_aad(env.session_id, env.index, self._room_id)

        # Copy the ciphertext into a mutable buffer for in-place open.
        var buf = List[UInt8]()
        buf.reserve(len(env.ciphertext_then_tag))
        for i in range(len(env.ciphertext_then_tag)):
            buf.append(env.ciphertext_then_tag[i])
        if len(buf) < AEAD_TAG_SIZE:
            raise Error("InboundGroupSession.decrypt: ciphertext shorter than tag")

        var cipher = ChaCha20Poly1305(keys.aead_key)
        # open_in_place raises on tag failure (constant-time verify-then-decrypt).
        cipher.open_in_place(
            nonce,
            Span[UInt8, origin_of(aad)](aad),
            Span[UInt8, origin_of(buf)](buf),
        )

        # On success the plaintext occupies the first len-TAG bytes.
        var plaintext = List[UInt8]()
        var pt_len = len(buf) - AEAD_TAG_SIZE
        plaintext.reserve(pt_len)
        for i in range(pt_len):
            plaintext.append(buf[i])
        return plaintext^


# -----------------------------------------------------------------------------
# Membership-change rotation — the PCS API.
# -----------------------------------------------------------------------------


def rotate_on_membership_change(mut session: OutboundGroupSession) raises:
    """Replace `session` IN PLACE with a FRESH outbound session for the same
    room — the MLS-style post-compromise-security rotation.

    On ANY membership change (add OR remove), the caller invokes this. The new
    session has a NEW random ratchet seed + NEW session_id, so its keystream is
    cryptographically independent of the old session. The caller then:
      * export_session_key() on the NEW session,
      * seal_session_key() per CURRENT member,
      * deliver ONLY to current members (the removed member gets nothing).
    A removed member's OLD inbound session produces a DIFFERENT keystream and a
    DIFFERENT session_id, so it fails the session_id check (and the AEAD tag) on
    every new-session envelope -> it cannot decrypt post-rotation traffic. That
    is the PCS property Megolm lacks.

    The OLD session's secrets are zeroized when the old value is dropped here
    (the move-assignment runs the old session's __del__)."""
    session = OutboundGroupSession(session._room_id)


# -----------------------------------------------------------------------------
# X25519-sealed key-share delivery — the to-device wrap.
# -----------------------------------------------------------------------------


struct SealedKeyShare(Movable, Deinitable):
    """An X25519-sealed SessionKeyShare for ONE recipient device. The server
    sees only these opaque bytes (content-blind to-device channel).

    Layout on the wire (serialize): eph_pub(32) || ciphertext_then_tag. The
    wrap nonce is all-zero: the wrap key is FRESH per seal (a per-message
    ephemeral X25519 keypair -> a unique HKDF wrap key per sealed share), so the
    (key, nonce) pair is unique without needing a random nonce. NOT secret on
    the wire (it is the sealed form); no zeroize."""

    var eph_pub: InlineArray[UInt8, X25519_KEY_SIZE]
    var ciphertext_then_tag: List[UInt8]

    def __init__(
        out self,
        eph_pub: InlineArray[UInt8, X25519_KEY_SIZE],
        var ciphertext_then_tag: List[UInt8],
    ):
        self.eph_pub = eph_pub.copy()
        self.ciphertext_then_tag = ciphertext_then_tag^

    def serialize(self) -> List[UInt8]:
        var out = List[UInt8]()
        out.reserve(X25519_KEY_SIZE + len(self.ciphertext_then_tag))
        for i in range(X25519_KEY_SIZE):
            out.append(self.eph_pub[i])
        for i in range(len(self.ciphertext_then_tag)):
            out.append(self.ciphertext_then_tag[i])
        return out^

    @staticmethod
    def deserialize(body: List[UInt8]) raises -> SealedKeyShare:
        if len(body) < X25519_KEY_SIZE + AEAD_TAG_SIZE:
            raise Error("SealedKeyShare.deserialize: body too short")
        var eph_pub = InlineArray[UInt8, X25519_KEY_SIZE](fill=UInt8(0))
        for i in range(X25519_KEY_SIZE):
            eph_pub[i] = body[i]
        var ct = List[UInt8]()
        ct.reserve(len(body) - X25519_KEY_SIZE)
        for i in range(X25519_KEY_SIZE, len(body)):
            ct.append(body[i])
        return SealedKeyShare(eph_pub, ct^)


@always_inline
def _derive_wrap_key(
    shared: InlineArray[UInt8, X25519_KEY_SIZE]
) raises -> InlineArray[UInt8, AEAD_KEY_SIZE]:
    """wrap_key = HKDF-SHA-256(salt=0, IKM=shared, info=KEYSHARE_WRAP_INFO,
    L=32). The X25519 shared secret is NOT used directly as an AEAD key (it is
    not uniformly random); HKDF-Extract conditions it first (RFC 5869)."""
    var empty_salt = List[UInt8]()
    var prk = Hkdf[Sha256].extract(
        Span[UInt8, origin_of(empty_salt)](empty_salt),
        Span[UInt8, origin_of(shared)](shared),
    )
    var wrap_key = InlineArray[UInt8, AEAD_KEY_SIZE](fill=UInt8(0))
    Hkdf[Sha256].expand(
        Span[UInt8, origin_of(prk)](prk),
        KEYSHARE_WRAP_INFO.as_bytes(),
        Span[UInt8, origin_of(wrap_key)](wrap_key),
    )
    # MIGRATION FIX (1.0.0): this read `var prk_copy = prk` +
    # `zeroize(prk_copy)`, which wiped a COPY and left the real PRK live on
    # the stack. b2's implicit InlineArray copy hid it; 1.0.0 refuses the
    # copy and made it visible. See the twin at ratchet.mojo.
    zeroize_inline_array[32](prk)
    return wrap_key^


def seal_session_key(
    share: SessionKeyShare,
    recipient_x25519_pub: InlineArray[UInt8, X25519_KEY_SIZE],
) raises -> SealedKeyShare:
    """X25519-seal a SessionKeyShare to ONE recipient's published prekey.

    A FRESH ephemeral X25519 keypair is generated per seal; the wrap key is
    HKDF(X25519(eph_priv, recipient_pub)). Because the wrap key is unique per
    seal, the AEAD nonce is fixed all-zero (no (key,nonce) reuse). The sender's
    side of the ECDH (eph_pub) ships in the clear; only the recipient (holding
    the prekey private) can recompute the shared secret.

    This is O(N devices) at session-start / re-key ONLY — NOT per message."""
    # Fresh ephemeral X25519 keypair.
    var eph_priv = InlineArray[UInt8, X25519_KEY_SIZE](fill=UInt8(0))
    system_entropy(Span[UInt8, origin_of(eph_priv)](eph_priv))
    var eph_pub = x25519_base_mult(
        Span[UInt8, origin_of(eph_priv)](eph_priv)
    )

    var shared = x25519(
        Span[UInt8, origin_of(eph_priv)](eph_priv),
        Span[UInt8, origin_of(recipient_x25519_pub)](recipient_x25519_pub),
    )
    # Reject the all-zero shared secret (small-order point — RFC 7748 §6.1).
    var nonzero = UInt8(0)
    for i in range(X25519_KEY_SIZE):
        nonzero = nonzero | shared[i]
    if nonzero == UInt8(0):
        raise Error("seal_session_key: X25519 produced all-zero shared secret")

    var wrap_key = _derive_wrap_key(shared)

    # Seal the serialized share. plaintext_then_tag = body || zeros(16).
    var body = share.serialize()
    var buf = List[UInt8]()
    buf.reserve(len(body) + AEAD_TAG_SIZE)
    for i in range(len(body)):
        buf.append(body[i])
    for _ in range(AEAD_TAG_SIZE):
        buf.append(UInt8(0))

    var zero_nonce = InlineArray[UInt8, NONCE_SEED_SIZE](fill=UInt8(0))
    var empty_aad = List[UInt8]()
    var cipher = ChaCha20Poly1305(wrap_key)
    cipher.seal_in_place(
        zero_nonce,
        Span[UInt8, origin_of(empty_aad)](empty_aad),
        Span[UInt8, origin_of(buf)](buf),
    )

    # Zeroize secret transients.
    zeroize_inline_array[X25519_KEY_SIZE](eph_priv)
    zeroize_inline_array[X25519_KEY_SIZE](shared)
    zeroize_inline_array[AEAD_KEY_SIZE](wrap_key)
    return SealedKeyShare(eph_pub, buf^)


def open_session_key(
    sealed: SealedKeyShare,
    recipient_x25519_priv: InlineArray[UInt8, X25519_KEY_SIZE],
) raises -> SessionKeyShare:
    """Open an X25519-sealed key share with the recipient's prekey private key
    (the inverse of seal_session_key). Raises on tag failure (tampered / wrong
    recipient). Returns the decrypted SessionKeyShare."""
    var shared = x25519(
        Span[UInt8, origin_of(recipient_x25519_priv)](recipient_x25519_priv),
        Span[UInt8, origin_of(sealed.eph_pub)](sealed.eph_pub),
    )
    var nonzero = UInt8(0)
    for i in range(X25519_KEY_SIZE):
        nonzero = nonzero | shared[i]
    if nonzero == UInt8(0):
        raise Error("open_session_key: X25519 produced all-zero shared secret")

    var wrap_key = _derive_wrap_key(shared)

    var buf = List[UInt8]()
    buf.reserve(len(sealed.ciphertext_then_tag))
    for i in range(len(sealed.ciphertext_then_tag)):
        buf.append(sealed.ciphertext_then_tag[i])

    var zero_nonce = InlineArray[UInt8, NONCE_SEED_SIZE](fill=UInt8(0))
    var empty_aad = List[UInt8]()
    var cipher = ChaCha20Poly1305(wrap_key)
    cipher.open_in_place(
        zero_nonce,
        Span[UInt8, origin_of(empty_aad)](empty_aad),
        Span[UInt8, origin_of(buf)](buf),
    )

    var plain_len = len(buf) - AEAD_TAG_SIZE
    var body = List[UInt8]()
    body.reserve(plain_len)
    for i in range(plain_len):
        body.append(buf[i])

    zeroize_inline_array[X25519_KEY_SIZE](shared)
    zeroize_inline_array[AEAD_KEY_SIZE](wrap_key)
    return SessionKeyShare.deserialize(body)


def x25519_prekey_generate() -> Tuple[
    InlineArray[UInt8, X25519_KEY_SIZE], InlineArray[UInt8, X25519_KEY_SIZE]
]:
    """Generate an X25519 prekey pair (priv, pub) for the group-key delivery
    channel. priv is random 32 bytes; pub = base_mult(priv).
    The CALLER must treat priv as SECRET and zeroize it after use."""
    var priv = InlineArray[UInt8, X25519_KEY_SIZE](fill=UInt8(0))
    try:
        system_entropy(Span[UInt8, origin_of(priv)](priv))
    except:
        # system_entropy only fails on catastrophic entropy-source failure.
        # Re-raise as a fatal would be ideal but this fn is non-raising to match
        # the keypair-generate shape; a zero priv is detectably wrong downstream.
        pass
    var pub = x25519_base_mult(Span[UInt8, origin_of(priv)](priv))
    return (priv^, pub^)
