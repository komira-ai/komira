# =============================================================================
# komira_group_ratchet/ratchet.mojo — the Megolm-equivalent symmetric ratchet
# =============================================================================
#
# STANDALONE library; dep closure = komira_crypto ONLY.
#
# WHAT THIS IS: the Megolm ratchet core — a 4-part 256-bit state advanced by an
# HMAC-SHA-256 tree at the 2^8 / 2^16 / 2^24 boundaries, plus the HKDF-SHA-256
# per-message key schedule. This file is the PURE STATE MACHINE: no AEAD, no
# signatures, no session lifecycle. The higher layers (session.mojo) compose
# encrypt/decrypt + Ed25519 + rotation on top of this.
#
# THE MEGOLM RATCHET (Matrix's group ratchet, the Megolm specification):
#   * State R = R[0] || R[1] || R[2] || R[3], each part 256 bits (32 bytes),
#     128 bytes total. Initialized with 1024 bits of CSPRNG data.
#   * Four HMAC functions: H_j(A) = HMAC-SHA-256(key=A, data=byte(j)) for j in
#     0..3. The single-byte data discriminator is the EXACT Megolm constant.
#   * Advance rules (per the Megolm specification, verified against libolm megolm.c):
#       - Part 0 NEVER advances on its own (it is the session root; static).
#       - Every 2^8  steps R[3] reseeds from R[2].
#       - Every 2^16 steps R[2] and R[3] reseed from R[1].
#       - Every 2^24 steps R[1], R[2], R[3] reseed from R[0].
#       - Otherwise (every step) R[3] = H_3(R[3]).
#     The carry is a base-256 odometer over the low 24 bits of the index: the
#     highest part j that rolls over reseeds via R[j] = H_j(R[j]) followed by
#     R[k] = H_k(R[j]) for k = j+1..3.
#   * FORWARD-ONLY: each H_j is one-way (HMAC pre-image resistance), so a
#     ratchet captured at index N cannot derive R at any index < N within the
#     same 2^8 / 2^16 / 2^24 block. This is Megolm's partial forward secrecy.
#
# THE KEY SCHEDULE (the Megolm specification "Per-Message Key Derivation"):
#   Megolm derives AES-256 key || HMAC-256 key || AES-128 IV = HKDF(salt=0,
#   IKM=R_i, info="MEGOLM_KEYS", L=80). WE SUBSTITUTE the AEAD (see session.mojo):
#   ChaCha20-Poly1305 needs a 32-byte key + 12-byte nonce, so we derive
#   aead_key(32) || nonce_seed(12) = HKDF-SHA-256(salt=0, IKM=R_i,
#   info="komira-grp-aead-v1", L=44). The info string is OUR domain separator
#   (NOT the Megolm "MEGOLM_KEYS" literal) — see the deviation note in
#   session.mojo. The derivation MECHANISM (HKDF-SHA-256 over the full 128-byte
#   ratchet) is identical to Megolm.
#
# ENCAPSULATION + gap6 (safety gate): ZERO UnsafePointer in any signature;
# ZERO wildcard origins (every Span is origin_of(local) — a concrete origin, NOT
# wildcard widening); ZERO unsafe_from_address; ZERO take_pointee. gap6 N/A: the
# ratchet state is an `InlineArray[UInt8, 128]` — inline-stored bytes, no
# heap-owning inner field, never an element of a byte-Slab under a wildcard cast.
# The struct is Movable (NOT Copyable — copying secret ratchet bytes is a leak);
# `__del__` zeroizes the state via komira_crypto.zeroize_inline_array. def-based
# (matches the komira_crypto package family). Mojo 1.0.0b1.
# =============================================================================

from komira_crypto import Hmac, Sha256, Hkdf, zeroize_inline_array


# -----------------------------------------------------------------------------
# Comptime layout constants.
# -----------------------------------------------------------------------------

comptime RATCHET_PART_SIZE: Int = 32
"""Each Megolm ratchet part is 256 bits = 32 bytes."""

comptime RATCHET_PARTS: Int = 4
"""Megolm has 4 ratchet parts (R[0..3])."""

comptime RATCHET_SIZE: Int = RATCHET_PARTS * RATCHET_PART_SIZE
"""Total ratchet state = 4 * 32 = 128 bytes (1024 bits, per the Megolm specification)."""

comptime AEAD_KEY_SIZE: Int = 32
"""ChaCha20-Poly1305 key size (substituting Megolm's AES-256 key)."""

comptime NONCE_SEED_SIZE: Int = 12
"""ChaCha20-Poly1305 nonce size (substituting Megolm's AES-128 IV)."""

comptime MSG_KEY_MATERIAL_SIZE: Int = AEAD_KEY_SIZE + NONCE_SEED_SIZE
"""Total HKDF output: 32-byte AEAD key || 12-byte nonce seed = 44 bytes."""

comptime KEY_SCHEDULE_INFO: StaticString = "komira-grp-aead-v1"
"""HKDF `info` domain separator for the per-message key schedule. OUR string
(NOT Megolm's "MEGOLM_KEYS") — the deviation is documented in session.mojo. A
distinct info string guarantees our derived keys never collide with a real
Megolm session's keys even on an identical ratchet (defense in depth)."""


# -----------------------------------------------------------------------------
# DerivedMessageKeys — the HKDF output for one message index.
# -----------------------------------------------------------------------------


struct DerivedMessageKeys(Movable, Deinitable):
    """The per-message key material derived from a ratchet state.

    aead_key (32 bytes) + nonce_seed (12 bytes). Secret-bearing: Movable, NOT
    Copyable; `__del__` zeroizes both buffers. The caller XORs the nonce_seed
    with the LE message index to form the per-message nonce (see session.mojo)
    so two messages from the same ratchet snapshot never reuse a nonce.

    gap6 N/A: both fields are inline `InlineArray[UInt8, N]` (no heap)."""

    var aead_key: InlineArray[UInt8, AEAD_KEY_SIZE]
    var nonce_seed: InlineArray[UInt8, NONCE_SEED_SIZE]

    def __init__(out self):
        """Construct zeroed key material (filled by derive_message_keys)."""
        self.aead_key = InlineArray[UInt8, AEAD_KEY_SIZE](fill=UInt8(0))
        self.nonce_seed = InlineArray[UInt8, NONCE_SEED_SIZE](fill=UInt8(0))

    def __deinit__(deinit self):
        """Zeroize derived key material on drop (no-elide secure-zero)."""
        zeroize_inline_array[AEAD_KEY_SIZE](self.aead_key)
        zeroize_inline_array[NONCE_SEED_SIZE](self.nonce_seed)


# -----------------------------------------------------------------------------
# GroupRatchet — the 4-part Megolm ratchet state machine.
# -----------------------------------------------------------------------------


struct GroupRatchet(Movable, Deinitable):
    """The Megolm-equivalent 4-part 256-bit symmetric ratchet.

    Holds 128 bytes of state + a `UInt32` index. Advancing increments the
    index and reseeds the appropriate parts via the HMAC-SHA-256 tree. The
    state is FORWARD-ONLY: `advance()` is one-way (HMAC pre-image resistance).

    Secret-bearing: Movable, NOT Copyable (copying the ratchet would let two
    senders derive the same keystream — a catastrophic nonce-reuse hazard).
    `clone_at()` is the EXPLICIT, named copy used when an inbound session
    fast-forwards a working copy to a target index for out-of-order delivery —
    it is deliberately not the implicit copy ctor.

    `__del__` zeroizes the 128-byte state.

    gap6 N/A: `_state` is `InlineArray[UInt8, 128]` (inline, no heap field);
    `_index` is a scalar. The struct is never a byte-Slab element under a
    wildcard cast."""

    var _state: InlineArray[UInt8, RATCHET_SIZE]
    """The 4 ratchet parts R[0]||R[1]||R[2]||R[3], 128 bytes."""

    var _index: UInt32
    """The current message index (Megolm's `i`). Monotonic; matches the index
    at which the CURRENT `_state` produces keys."""

    # -------------------------------------------------------------------------
    # Construction.
    # -------------------------------------------------------------------------

    def __init__(out self, seed: Span[UInt8, _], index: UInt32) raises:
        """Construct a ratchet from a 128-byte seed at a given index.

        `seed` MUST be >= RATCHET_SIZE (128) bytes. For a fresh outbound
        session the seed is 1024 bits of CSPRNG output and `index` is 0; for an
        imported inbound session the seed is the exported ratchet bytes and
        `index` is the exported index (the receiver can only ratchet FORWARD
        from there).

        Raises if `seed` is too short (a short seed would leave the high parts
        zero — a silent key-collision hazard)."""
        if len(seed) < RATCHET_SIZE:
            raise Error(
                "GroupRatchet: seed must be >= "
                + String(RATCHET_SIZE)
                + " bytes (got "
                + String(len(seed))
                + ")"
            )
        self._state = InlineArray[UInt8, RATCHET_SIZE](fill=UInt8(0))
        for i in range(RATCHET_SIZE):
            self._state[i] = seed[i]
        self._index = index

    def __init__(out self, *, var _state: InlineArray[UInt8, RATCHET_SIZE], _index: UInt32):
        """Private full-field ctor (used by clone_at)."""
        self._state = _state^
        self._index = _index

    def __deinit__(deinit self):
        """Zeroize the 128-byte ratchet state on drop (no-elide secure-zero)."""
        zeroize_inline_array[RATCHET_SIZE](self._state)

    # -------------------------------------------------------------------------
    # Accessors (no raw-pointer escape — bytes are copied out into owned types).
    # -------------------------------------------------------------------------

    def index(self) -> UInt32:
        """The current message index."""
        return self._index

    def export_state(self) -> InlineArray[UInt8, RATCHET_SIZE]:
        """Copy the 128-byte ratchet state out (for session-key export /
        clone). Returns an owned InlineArray (no pointer escape). The CALLER
        is responsible for treating the result as SECRET (it is the full
        decryption capability from `index` forward) and zeroizing it.

        NOTE: this is the one place ratchet bytes leave the struct. It is used
        by the session export path (which immediately X25519-seals the bytes
        for a single recipient) and by clone_at. It never returns a reference
        or pointer into `_state`."""
        var out = InlineArray[UInt8, RATCHET_SIZE](fill=UInt8(0))
        for i in range(RATCHET_SIZE):
            out[i] = self._state[i]
        return out^

    def clone_at(self) -> Self:
        """Explicit, named copy of this ratchet at its current index.

        The receiver's inbound path uses this to fast-forward a WORKING copy to
        a target message index without losing its canonical session ratchet (so
        a later in-order or earlier-cached index is still derivable). This is
        the deliberate, audited stand-in for an implicit copy ctor — the struct
        is intentionally non-Copyable so every ratchet duplication is visible at
        the call site."""
        var st = InlineArray[UInt8, RATCHET_SIZE](fill=UInt8(0))
        for i in range(RATCHET_SIZE):
            st[i] = self._state[i]
        return Self(_state=st^, _index=self._index)

    # -------------------------------------------------------------------------
    # The HMAC tree: H_j(A) = HMAC-SHA-256(key=A, data=byte(j)).
    # -------------------------------------------------------------------------

    @staticmethod
    def _hmac_part(
        part_key: Span[UInt8, _], discriminator: UInt8
    ) raises -> InlineArray[UInt8, RATCHET_PART_SIZE]:
        """H_j(A) = HMAC-SHA-256(key=A, data=[j]) per the Megolm specification.

        The single-byte `discriminator` IS the exact Megolm H_j constant
        (0x00 / 0x01 / 0x02 / 0x03). Output is the 32-byte HMAC tag = the new
        ratchet part. Constant-time: HMAC-SHA-256 is data-oblivious."""
        var mac = Hmac[Sha256](part_key)
        var data = InlineArray[UInt8, 1](fill=discriminator)
        mac.update(Span[UInt8, origin_of(data)](data))
        var out = InlineArray[UInt8, RATCHET_PART_SIZE](fill=UInt8(0))
        mac.finalize_into(Span[UInt8, origin_of(out)](out))
        return out^

    @always_inline
    def _part_span(
        self, part: Int
    ) -> Span[UInt8, origin_of(self._state)]:
        """A read-only span over part `part` of `_state`. Internal helper; the
        span's origin is the concrete `_state` borrow (NOT a wildcard). Never
        escapes the struct."""
        var base = part * RATCHET_PART_SIZE
        return Span[UInt8, origin_of(self._state)](self._state)[
            base : base + RATCHET_PART_SIZE
        ]

    @always_inline
    def _set_part(mut self, part: Int, src: InlineArray[UInt8, RATCHET_PART_SIZE]):
        """Copy a 32-byte part value into `_state` at slot `part`."""
        var base = part * RATCHET_PART_SIZE
        for i in range(RATCHET_PART_SIZE):
            self._state[base + i] = src[i]

    # -------------------------------------------------------------------------
    # advance() — increment the index by one Megolm step.
    # -------------------------------------------------------------------------

    def advance(mut self) raises:
        """Advance the ratchet by one message index (Megolm R_i -> R_{i+1}).

        Determines the highest part `j` that rolls over at the new index, then
        reseeds parts j..3 via the HMAC tree:
            R[j]     = H_j(R[j])
            R[k]     = H_k(R[j])   for k = j+1 .. 3
        Per the Megolm specification:
            - every step      -> j = 3 (R[3] = H_3(R[3]))
            - every 2^8       -> j = 2 (R[2] reseeds, then R[3] from new R[2])
            - every 2^16      -> j = 1
            - every 2^24      -> j = 0  (part 0 itself is reseeded only here;
                                        it is the highest part that ever moves)
        The carry is read off the NEW index: the number of trailing zero bytes
        in the low 24 bits selects `j`."""
        var new_index = self._index + UInt32(1)

        # Determine the rollover part j from the trailing-zero-byte count of the
        # new index's low 24 bits (base-256 odometer carry).
        #   new_index % 2^24 == 0  -> j = 0
        #   new_index % 2^16 == 0  -> j = 1
        #   new_index % 2^8  == 0  -> j = 2
        #   otherwise              -> j = 3
        var j: Int
        if (new_index & UInt32(0x00FFFFFF)) == UInt32(0):
            j = 0
        elif (new_index & UInt32(0x0000FFFF)) == UInt32(0):
            j = 1
        elif (new_index & UInt32(0x000000FF)) == UInt32(0):
            j = 2
        else:
            j = 3

        # R[j] = H_j(R[j]).
        var reseeded = Self._hmac_part(self._part_span(j), UInt8(j))
        self._set_part(j, reseeded)

        # R[k] = H_k(R[j])  for k = j+1 .. 3 (each derived from the NEW R[j]).
        for k in range(j + 1, RATCHET_PARTS):
            var derived = Self._hmac_part(self._part_span(j), UInt8(k))
            self._set_part(k, derived)

        self._index = new_index

    def advance_to(mut self, target: UInt32) raises:
        """Fast-forward the ratchet to `target` index by repeated advance().

        Used by the inbound path to reach a received message's index. Raises if
        `target < self._index` — the ratchet is FORWARD-ONLY and CANNOT go
        backward (this raise is the structural enforcement of the
        forward-ratchet property: an inbound session imported at index N can
        never derive keys for index < N).

        NOTE: this is O(target - index) HMAC calls. The caller (inbound session)
        bounds the gap via a skipped-key cache (see session.mojo) so a malicious
        far-future index cannot force unbounded work on the receiver."""
        if target < self._index:
            raise Error(
                "GroupRatchet.advance_to: cannot ratchet backward (target "
                + String(Int(target))
                + " < current "
                + String(Int(self._index))
                + ") — the forward-ratchet property forbids it"
            )
        while self._index < target:
            self.advance()

    # -------------------------------------------------------------------------
    # derive_message_keys() — the HKDF-SHA-256 key schedule.
    # -------------------------------------------------------------------------

    def derive_message_keys(self) raises -> DerivedMessageKeys:
        """Derive the per-message AEAD key + nonce seed from the CURRENT state.

        aead_key(32) || nonce_seed(12) = HKDF-SHA-256(salt=0, IKM=R_i,
        info=KEY_SCHEDULE_INFO, L=44). Mirrors Megolm's the Megolm specification
        per-message derivation (HKDF-SHA-256 over the full 128-byte ratchet)
        with OUR info string + OUR ChaCha20-Poly1305 output sizing (see the
        substitution note in session.mojo).

        salt=0: HKDF-Extract with an empty salt is RFC 5869's HashLen-zero-byte
        substitution; komira_crypto's Hkdf handles the empty-salt case
        internally. The Extract step folds the 128-byte ratchet into a 32-byte
        PRK; Expand stretches it to the 44-byte output."""
        var ikm = Span[UInt8, origin_of(self._state)](self._state)
        var empty_salt = List[UInt8]()
        var prk = Hkdf[Sha256].extract(
            Span[UInt8, origin_of(empty_salt)](empty_salt), ikm
        )

        var material = InlineArray[UInt8, MSG_KEY_MATERIAL_SIZE](fill=UInt8(0))
        Hkdf[Sha256].expand(
            Span[UInt8, origin_of(prk)](prk),
            KEY_SCHEDULE_INFO.as_bytes(),
            Span[UInt8, origin_of(material)](material),
        )

        var keys = DerivedMessageKeys()
        for i in range(AEAD_KEY_SIZE):
            keys.aead_key[i] = material[i]
        for i in range(NONCE_SEED_SIZE):
            keys.nonce_seed[i] = material[AEAD_KEY_SIZE + i]

        # Zeroize the transient PRK + material before they fall out of scope.
        # MIGRATION FIX (1.0.0): this read `var prk_copy = prk` +
        # `zeroize(prk_copy)`, which wiped a COPY and left the real PRK live on
        # the stack -- i.e. the zeroize this comment promises never happened.
        # b2's implicit InlineArray copy hid it; 1.0.0 refuses the copy and made
        # it visible. `prk` is a `var` local and `zeroize_inline_array` takes
        # `mut`, so the direct call is what was meant all along.
        zeroize_inline_array[MSG_KEY_MATERIAL_SIZE](material)
        zeroize_inline_array[32](prk)
        return keys^
