# =============================================================================
# firestore_cdc_cursor.mojo — the Firestore Watch CDC checkpoint cursor +
#   the read_time -> fixed-width-comparable-sequence ordering-key normalization.
# =============================================================================
#
# CDC-Firestore ChangeSource. The Firestore Watch CDC listener conforms to
# komira_snapshotter's `MultiShardChangeStreamListener` seam, so a generic
# consumer of that seam needs no Firestore knowledge. Firestore's resumable position is a PAIR — a `resume_token`
# (opaque bytes, resumes the watch) + a `read_time` (a consistent snapshot
# Timestamp) — but the seam exposes exactly TWO primitives per record/shard:
#   * `ChangeRecord.sequence_number` — a single String ordering key;
#   * the shard cursor — a single opaque String.
# This module maps Firestore's pair onto those two primitives.
#
# (1) THE ORDERING KEY (design decision #1). A Firestore `read_time` (Timestamp:
#     int64 `seconds` + int32 `nanos`) normalizes to a FIXED-WIDTH ZERO-PADDED
#     decimal string:
#         seconds  -> 12 digits (good past year 31,000; Firestore seconds are ~1.7e9)
#         nanos    ->  9 digits (0..999_999_999)
#         sequence  = <12-digit seconds><9-digit nanos>  (a 21-char string)
#     This is used AS `ChangeRecord.sequence_number`, so a numeric magnitude
#     compare (significant-digit count, then digits) orders records correctly,
#     and because the width is FIXED, a plain lexicographic compare agrees (older read_time < newer). We deliberately do NOT compute
#     `seconds*1e9 + nanos` in Int64 — that product (~1.7e18 today, and >9.2e18
#     Int64-MAX for seconds past ~year-2262) would overflow; the concatenated
#     fixed-width form is lossless and comparison-correct with no bignum.
#
# (2) THE CHECKPOINT CURSOR (design decision #2). The seam's single OPAQUE cursor
#     String encodes the PAIR `(read_time, resume_token)`:
#         "<sequence>|<hex(resume_token)>"
#     where <sequence> is the 21-char read_time key (above) and hex(resume_token)
#     is the lowercase hex of the opaque token bytes (so a leading zero byte /
#     any binary content survives — a raw String cannot hold arbitrary bytes).
#     `open_shard(after)` decodes this back on resume: the resume_token re-opens
#     the watch; the read_time is the resume boundary. A consumer of the seam
#     treats it as an opaque String.
#
# ENCAPSULATION. ZERO UnsafePointer; ZERO wildcard origins; ZERO
# unsafe_from_address. Pure String / List[UInt8] helpers — NO cross-package dep
# (the cursor is provider-internal; the generic pipeline only ever sees the
# opaque String). `def`-based, Mojo 1.0.0b2.
# =============================================================================


comptime _SEQ_SECONDS_WIDTH: Int = 12
comptime _SEQ_NANOS_WIDTH: Int = 9
# The fixed sequence width = seconds digits + nanos digits.
comptime FIRESTORE_SEQUENCE_WIDTH: Int = _SEQ_SECONDS_WIDTH + _SEQ_NANOS_WIDTH


# =============================================================================
# §1 — read_time -> the fixed-width comparable ordering-key string.
# =============================================================================


def read_time_to_sequence(seconds: Int64, nanos: Int64) -> String:
    """Normalize a Firestore `read_time` (Timestamp seconds + nanos) to a
    FIXED-WIDTH ZERO-PADDED decimal ordering key: a 12-digit seconds field
    followed by a 9-digit nanos field (21 chars total).

    The width is fixed so an older read_time sorts strictly before a newer one
    under BOTH a numeric (significant-digit magnitude) compare AND a naive
    lexicographic compare. Negative seconds (pre-epoch — not expected from
    Firestore) clamp to 0; nanos out of [0, 1e9) clamp into range defensively so
    the key is always well-formed and monotonic."""
    var s = seconds
    if s < Int64(0):
        s = Int64(0)
    var n = nanos
    if n < Int64(0):
        n = Int64(0)
    if n > Int64(999_999_999):
        n = Int64(999_999_999)
    return _pad_decimal(s, _SEQ_SECONDS_WIDTH) + _pad_decimal(n, _SEQ_NANOS_WIDTH)


def _pad_decimal(v: Int64, width: Int) -> String:
    """Left-zero-pad a non-negative Int64 to `width` digits. A value with MORE
    than `width` digits is returned in full (never truncated — correctness over
    fixed width if the clock somehow exceeds the field), so ordering stays
    monotonic even at the boundary."""
    var digits = String(v)
    var pad = width - digits.byte_length()
    if pad <= 0:
        return digits^
    var out = String("")
    for _ in range(pad):
        out += "0"
    out += digits
    return out^


# =============================================================================
# §2 — FirestoreCursor — the decoded (read_time, resume_token) pair.
# =============================================================================


struct FirestoreCursor(Copyable, Movable, Deinitable):
    """A decoded Firestore CDC checkpoint cursor: the read_time (seconds + nanos)
    + the opaque resume_token bytes + a presence flag.

    `has_position` is False for a COLD START (an empty cursor String) — distinct
    from a present cursor whose `resume_token` happens to be empty (a valid resume
    at a read_time with no token yet). The driver cold-starts the watch iff
    `has_position` is False.

    Layout: a plain owned-field struct (Int64 + `List[UInt8]` + Bool) in a plain
    local — no pointer field, no byte-slab."""

    var read_time_seconds: Int64
    var read_time_nanos: Int64
    var resume_token: List[UInt8]
    var has_position: Bool

    def __init__(
        out self,
        read_time_seconds: Int64,
        read_time_nanos: Int64,
        var resume_token: List[UInt8],
        has_position: Bool,
    ):
        self.read_time_seconds = read_time_seconds
        self.read_time_nanos = read_time_nanos
        self.resume_token = resume_token^
        self.has_position = has_position

    def copy(self) -> Self:
        var tok = List[UInt8]()
        for i in range(len(self.resume_token)):
            tok.append(self.resume_token[i])
        return Self(
            self.read_time_seconds, self.read_time_nanos, tok^, self.has_position
        )

    @always_inline
    def sequence(self) -> String:
        """The ordering-key form of this cursor's read_time (== the
        `ChangeRecord.sequence_number` the listener stamps)."""
        return read_time_to_sequence(self.read_time_seconds, self.read_time_nanos)


# =============================================================================
# §3 — encode / decode the opaque composite cursor String.
# =============================================================================


def encode_firestore_cursor(
    read_time_seconds: Int64, read_time_nanos: Int64, resume_token: List[UInt8]
) -> String:
    """Encode `(read_time, resume_token)` into the seam's single opaque cursor
    String: "<21-char sequence>|<hex(resume_token)>". The hex encoding lets an
    arbitrary-byte token (incl. leading zeros) survive a String round-trip."""
    return (
        read_time_to_sequence(read_time_seconds, read_time_nanos)
        + String("|")
        + _bytes_to_hex(resume_token)
    )


def decode_firestore_cursor(cursor: String) -> FirestoreCursor:
    """Decode the opaque cursor String back into a FirestoreCursor.

    Accepts TWO forms:
      * "<21-char sequence>|<hex(resume_token)>" — the FULL composite cursor
        (in-session `next_cursor`), carrying BOTH the read_time + the resume_token.
      * "<21-char sequence>" — a BARE read_time sequence, NO '|' separator. This
        is the CRASH-SAFE resume position: the generic ingest pipeline stamps only
        each record's `sequence_number` (the read_time sequence) into the Iceberg
        snapshot summary, so the position that survives a crash and is passed back
        to `open_shard(after)` is the bare read_time sequence, WITHOUT the
        resume_token. That is sufficient — Firestore Watch resumes by `read_time`
        (Target.read_time) when no resume_token is available; the resume_token is a
        same-session optimization, not crash-critical. The decoded cursor then has
        an EMPTY resume_token but a valid read_time (has_position=True).

    An EMPTY cursor -> has_position=False (cold start). A malformed cursor (a bad
    sequence field) also -> cold start (defensive: a corrupt checkpoint restarts
    the watch rather than crashing)."""
    if cursor.byte_length() == 0:
        return FirestoreCursor(Int64(0), Int64(0), List[UInt8](), False)
    var bs = cursor.as_bytes()
    # Find the '|' separator (absent for the bare read_time-sequence form).
    var bar = -1
    for i in range(len(bs)):
        if bs[i] == UInt8(ord("|")):
            bar = i
            break
    if bar < 0:
        # BARE read_time sequence (crash-safe resume position stamped by the
        # generic pipeline). Parse it as the whole string; no resume_token.
        var parsed_bare = _parse_sequence(cursor)
        if not parsed_bare.ok:
            return FirestoreCursor(Int64(0), Int64(0), List[UInt8](), False)
        return FirestoreCursor(
            parsed_bare.seconds, parsed_bare.nanos, List[UInt8](), True
        )
    # Composite form: sequence field = bs[:bar] (fixed-width 21-char), then hex.
    var seq = String("")
    for i in range(bar):
        seq += chr(Int(bs[i]))
    var parsed = _parse_sequence(seq)
    if not parsed.ok:
        return FirestoreCursor(Int64(0), Int64(0), List[UInt8](), False)
    # Resume token hex = bs[bar+1:].
    var hex = String("")
    for i in range(bar + 1, len(bs)):
        hex += chr(Int(bs[i]))
    var token = _hex_to_bytes(hex)
    return FirestoreCursor(parsed.seconds, parsed.nanos, token^, True)


@fieldwise_init
struct _ParsedSequence(Copyable, Movable, Deinitable):
    """The result of parsing a fixed-width sequence field (a plain POD struct —
    a Mojo b2 tuple return of mixed Bool/Int64 does not type-check reliably, so a
    fieldwise struct is used instead)."""

    var ok: Bool
    var seconds: Int64
    var nanos: Int64


def _parse_sequence(seq: String) -> _ParsedSequence:
    """Parse a fixed-width sequence "<12 seconds><9 nanos>" back into
    (ok, seconds, nanos). Returns ok=False for any wrong-width / non-digit
    field (a corrupt checkpoint)."""
    var sb = seq.as_bytes()
    if len(sb) != FIRESTORE_SEQUENCE_WIDTH:
        return _ParsedSequence(False, Int64(0), Int64(0))
    var seconds = Int64(0)
    for i in range(_SEQ_SECONDS_WIDTH):
        var c = sb[i]
        if c < UInt8(ord("0")) or c > UInt8(ord("9")):
            return _ParsedSequence(False, Int64(0), Int64(0))
        seconds = seconds * Int64(10) + Int64(Int(c) - ord("0"))
    var nanos = Int64(0)
    for i in range(_SEQ_SECONDS_WIDTH, FIRESTORE_SEQUENCE_WIDTH):
        var c = sb[i]
        if c < UInt8(ord("0")) or c > UInt8(ord("9")):
            return _ParsedSequence(False, Int64(0), Int64(0))
        nanos = nanos * Int64(10) + Int64(Int(c) - ord("0"))
    return _ParsedSequence(True, seconds, nanos)


# =============================================================================
# §4 — hex helpers (arbitrary-byte token survives a String round-trip).
# =============================================================================


@always_inline
def _bytes_to_hex(raw: List[UInt8]) -> String:
    comptime HEX = String("0123456789abcdef")
    var out = String("")
    var hb = HEX.as_bytes()
    for i in range(len(raw)):
        var b = Int(raw[i])
        out += chr(Int(hb[(b >> 4) & 0xF]))
        out += chr(Int(hb[b & 0xF]))
    return out^


def _hex_to_bytes(hex: String) -> List[UInt8]:
    """Decode a lowercase/uppercase hex string into bytes. An odd-length or
    non-hex string yields the bytes decoded so far (defensive — a corrupt token
    restarts the watch via the empty/short token, never crashes)."""
    var hb = hex.as_bytes()
    var out = List[UInt8]()
    var i = 0
    while i + 1 < len(hb):
        var hi = _hex_nibble(hb[i])
        var lo = _hex_nibble(hb[i + 1])
        if hi < 0 or lo < 0:
            break
        out.append(UInt8((hi << 4) | lo))
        i += 2
    return out^


@always_inline
def _hex_nibble(c: UInt8) -> Int:
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return Int(c) - ord("0")
    if c >= UInt8(ord("a")) and c <= UInt8(ord("f")):
        return Int(c) - ord("a") + 10
    if c >= UInt8(ord("A")) and c <= UInt8(ord("F")):
        return Int(c) - ord("A") + 10
    return -1
