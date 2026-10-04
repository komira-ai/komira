# =============================================================================
# src/kci_pkg_upload/identity.mojo — what "the same bytes" means when
#   one side is us and the other is a package registry.
# =============================================================================
#
# ⭐ IDENTITY VERSUS WITNESS. Our identity for a file is always the sha256 of
# the exact bytes we upload. A registry exposes whatever digest it chooses:
# PyPI and conda repodata expose sha256; npmjs exposes only sha512
# (as an SRI string) and sha1. So a `ContentIdentity` carries three fields, and
# a field a side does not expose is EMPTY.
#
# ⛔ COMPARED FIELD BY FIELD, NEVER ACROSS FIELDS. A sha512 is never compared
# against a sha256. And an empty field is "not exposed", never "equal to
# anything": two identities that share NO exposed field cannot be called equal.
# `identity_matches` answers that case as its own kind, NO_COMMON_FIELD, which
# every caller must treat as a REFUSAL. The alternative — comparing the fields
# both sides expose and calling an empty intersection "no difference found" —
# is equality by vacuity, and it would let a substrate that exposes nothing we
# compute read as PRESENT_IDENTICAL forever.
#
# Hex fields compare ASCII-case-insensitively (a registry that answers
# uppercase hex is naming the same digest); the SRI field is base64 and
# compares exactly.
#
# Encapsulation: owned `String` values; no pointer, no wildcard
# origin.
# =============================================================================

from komira_crypto import Sha1, Sha512, hex_lower, sha256
from komira_encoding import base64_encode


# The three answers `identity_matches` can give. Only MATCH is agreement.
comptime IDENTITY_MATCH: Int = 0
comptime IDENTITY_MISMATCH: Int = 1
comptime IDENTITY_NO_COMMON_FIELD: Int = 2


def identity_match_name(kind: Int) -> String:
    if kind == IDENTITY_MATCH:
        return String("MATCH")
    if kind == IDENTITY_MISMATCH:
        return String("MISMATCH")
    if kind == IDENTITY_NO_COMMON_FIELD:
        return String("NO_COMMON_FIELD")
    return String("UNKNOWN_IDENTITY_MATCH(") + String(kind) + String(")")


struct ContentIdentity(Copyable, Movable, Deinitable):
    """The digests one side exposes for a file. EMPTY = not exposed.

    `sha256_hex` — lowercase hex (64 chars) when exposed.
    `sha512_sri` — `sha512-<base64>` (the npm `dist.integrity` shape).
    `sha1_hex`   — lowercase hex (40 chars), the npm `dist.shasum` witness.

    Layout: three owned Strings. No pointer field."""

    var sha256_hex: String
    var sha512_sri: String
    var sha1_hex: String

    def __init__(
        out self,
        var sha256_hex: String,
        var sha512_sri: String,
        var sha1_hex: String,
    ):
        self.sha256_hex = sha256_hex^
        self.sha512_sri = sha512_sri^
        self.sha1_hex = sha1_hex^

    @staticmethod
    def none() -> ContentIdentity:
        """An identity that exposes nothing (a registry answer with no digest
        we compute). Compared against anything, it is NO_COMMON_FIELD."""
        return ContentIdentity(String(""), String(""), String(""))

    @staticmethod
    def of_sha256_hex(var hex: String) -> ContentIdentity:
        """An identity that exposes only sha256 (PyPI, conda repodata)."""
        return ContentIdentity(hex^, String(""), String(""))

    def exposes_nothing(self) -> Bool:
        return (
            self.sha256_hex.byte_length() == 0
            and self.sha512_sri.byte_length() == 0
            and self.sha1_hex.byte_length() == 0
        )

    def describe(self) -> String:
        """The exposed fields as `sha256=<hex> sha512=<sri> sha1=<hex>`, or
        `(no digest exposed)`. For refusals that name both identities."""
        var out = String("")
        if self.sha256_hex.byte_length() > 0:
            out += String("sha256=") + self.sha256_hex
        if self.sha512_sri.byte_length() > 0:
            if out.byte_length() > 0:
                out += String(" ")
            out += String("sha512=") + self.sha512_sri
        if self.sha1_hex.byte_length() > 0:
            if out.byte_length() > 0:
                out += String(" ")
            out += String("sha1=") + self.sha1_hex
        if out.byte_length() == 0:
            return String("(no digest exposed)")
        return out^


def content_identity_of(data: Span[UInt8, _]) -> ContentIdentity:
    """OUR identity for `data`: all three fields, computed from the bytes.

    This is the only constructor of a fully-populated identity, so an identity
    that claims to describe some bytes cannot have been typed in beside them."""
    var sha256_hex = hex_lower(Span(sha256(data)))

    var h512 = Sha512()
    h512.update(data)
    var d512 = Array[UInt8, 64](fill=0)
    h512.finalize_into(d512)
    var sri = String("sha512-") + base64_encode(Span(d512))

    var h1 = Sha1()
    h1.update(data)
    var d1 = Array[UInt8, 20](fill=0)
    h1.finalize_into(d1)
    var sha1_hex = hex_lower(Span(d1))

    return ContentIdentity(sha256_hex^, sri^, sha1_hex^)


def ascii_lower(s: String) -> String:
    var out = String("")
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if c >= UInt8(65) and c <= UInt8(90):
            c += UInt8(32)
        out += chr(Int(c))
    return out^


def _hex_field_equal(a: String, b: String) -> Bool:
    return ascii_lower(a) == ascii_lower(b)


def identity_matches(ours: ContentIdentity, theirs: ContentIdentity) -> Int:
    """Compare two identities FIELD BY FIELD.

      MATCH           iff at least ONE field is exposed on BOTH sides, and
                      every such field is equal;
      MISMATCH        iff some field exposed on both sides differs;
      NO_COMMON_FIELD iff no field is exposed on both sides. A REFUSAL, never
                      "equal by vacuity" (see the file header).

    A field exposed on only one side is ignored: that is the witness case
    (npm exposes sha512 and sha1, we also hold sha256), not a difference."""
    var compared = 0
    if ours.sha256_hex.byte_length() > 0 and theirs.sha256_hex.byte_length() > 0:
        compared += 1
        if not _hex_field_equal(ours.sha256_hex, theirs.sha256_hex):
            return IDENTITY_MISMATCH
    if ours.sha512_sri.byte_length() > 0 and theirs.sha512_sri.byte_length() > 0:
        compared += 1
        if ours.sha512_sri != theirs.sha512_sri:
            return IDENTITY_MISMATCH
    if ours.sha1_hex.byte_length() > 0 and theirs.sha1_hex.byte_length() > 0:
        compared += 1
        if not _hex_field_equal(ours.sha1_hex, theirs.sha1_hex):
            return IDENTITY_MISMATCH
    if compared == 0:
        return IDENTITY_NO_COMMON_FIELD
    return IDENTITY_MATCH
