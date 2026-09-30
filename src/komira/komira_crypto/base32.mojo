# =============================================================================
# komira_crypto/base32.mojo — RFC 4648 base32 (no padding) encode + decode.
# =============================================================================
#
# TOTP (RFC 6238) provisioning requires the shared secret rendered in BASE32:
# authenticator apps (Google Authenticator / 1Password / Authy) accept the
# secret ONLY as base32, not hex/base64. `komira_crypto`'s base64 is an
# AWS-LC FFI re-export; base32 is small and deterministic, so it is written
# here in Mojo.
#
# This is DETERMINISTIC ENCODING, not cryptography (no key material, no timing
# discipline needed) — safe to implement in pure Mojo with an exhaustive
# round-trip test (tests/test_base32_roundtrip.mojo).
#
# RFC 4648 §6 alphabet (the "standard" base32, A–Z 2–7). We emit WITHOUT `=`
# padding (the otpauth:// secret convention drops padding) and DECODE tolerating
# absent padding (and, tolerantly, an incidental `=` tail / lowercase input).
#
# Encapsulation: `Span[UInt8, _]` / `String` / `List[UInt8]` in and out —
# ZERO UnsafePointer crosses any boundary; no wildcard origin.
# =============================================================================


# RFC 4648 §6 base32 alphabet: 5-bit value -> ASCII symbol.
comptime _B32_ALPHABET: StaticString = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"


def base32_encode_nopad(data: Span[UInt8, _]) -> String:
    """RFC 4648 §6 base32 encode WITHOUT `=` padding.

    Packs the input bytes MSB-first into a bitstream and slices it into 5-bit
    groups, each mapped to the base32 alphabet. A trailing partial group (the
    final <5 bits) is zero-padded on the RIGHT to a full symbol (the RFC 4648
    canonical form), then the `=` pad characters that a padded encoding would
    append are OMITTED (the otpauth:// secret convention).
    """
    var out = String()
    var buffer: UInt32 = 0  # accumulates up to 12 pending bits (fits in UInt32).
    var bits_in_buffer: Int = 0
    for i in range(len(data)):
        # Shift the next byte in at the LOW end (MSB-first bitstream).
        buffer = (buffer << 8) | UInt32(Int(data[i]))
        bits_in_buffer += 8
        # Drain every full 5-bit group from the HIGH end.
        while bits_in_buffer >= 5:
            bits_in_buffer -= 5
            var idx = Int((buffer >> UInt32(bits_in_buffer)) & UInt32(0x1F))
            out += _b32_symbol(idx)
    # Flush any trailing partial group (right-pad with zero bits to 5).
    if bits_in_buffer > 0:
        var idx = Int((buffer << UInt32(5 - bits_in_buffer)) & UInt32(0x1F))
        out += _b32_symbol(idx)
    return out^


def base32_decode(s: String) raises -> List[UInt8]:
    """RFC 4648 §6 base32 decode. TOLERANT: accepts input with OR without `=`
    padding, ignores an incidental `=` tail, and accepts lowercase letters
    (canonicalized to uppercase). A non-alphabet, non-`=`, non-whitespace
    character RAISES (a strict reject on genuine garbage).

    Reconstructs the MSB-first bitstream from the 5-bit symbol values and slices
    it back into whole bytes; any trailing partial (<8) bits are the encoder's
    right-pad and are DISCARDED (they are zero on a well-formed encoding)."""
    var out = List[UInt8]()
    var buffer: UInt32 = 0
    var bits_in_buffer: Int = 0
    var sb = s.as_bytes()
    for i in range(len(sb)):
        var c = sb[i]
        # Skip padding + ASCII whitespace (spaces/newlines a copy-paste may add).
        if (
            c == UInt8(ord("="))
            or c == UInt8(ord(" "))
            or c == UInt8(ord("\n"))
            or c == UInt8(ord("\r"))
            or c == UInt8(ord("\t"))
        ):
            continue
        var val = _b32_value(c)
        if val < 0:
            raise Error(
                String("base32_decode: invalid character '")
                + chr(Int(c))
                + String("'")
            )
        buffer = (buffer << 5) | UInt32(val)
        bits_in_buffer += 5
        # Emit a whole byte whenever 8+ bits are buffered.
        if bits_in_buffer >= 8:
            bits_in_buffer -= 8
            out.append(UInt8(Int((buffer >> UInt32(bits_in_buffer)) & UInt32(0xFF))))
    return out^


@always_inline
def _b32_symbol(idx: Int) -> String:
    """The base32 symbol for a 5-bit value (0..31)."""
    var alpha = _B32_ALPHABET.as_bytes()
    return chr(Int(alpha[idx]))


def _b32_value(c: UInt8) -> Int:
    """The 5-bit value of a base32 character, or -1 if not in the alphabet.
    Accepts BOTH cases (A–Z / a–z) + digits 2–7 (RFC 4648 §6)."""
    # A–Z -> 0..25
    if c >= UInt8(ord("A")) and c <= UInt8(ord("Z")):
        return Int(c) - ord("A")
    # a–z -> 0..25 (lowercase tolerance)
    if c >= UInt8(ord("a")) and c <= UInt8(ord("z")):
        return Int(c) - ord("a")
    # 2–7 -> 26..31
    if c >= UInt8(ord("2")) and c <= UInt8(ord("7")):
        return Int(c) - ord("2") + 26
    return -1
