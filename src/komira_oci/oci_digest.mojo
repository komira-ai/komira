# =============================================================================
# oci_digest.mojo — content-addressing: the ONE place
#   this package turns bytes into a `sha256:…` digest.
# =============================================================================
#
# THE PROPERTY THIS FILE EXISTS TO DEFEND. A `stage` promote is a copy that
# PRESERVES the digest. "Preserves" is only a real claim if the digest is
# recomputed from the bytes that actually moved — anything else is the registry
# telling us what it thinks it stored.
#
# ⚠ WHY THE COPIER MUST NEVER RE-SERIALIZE A MANIFEST. A manifest's digest covers
# its EXACT bytes — whitespace, key order, trailing newline and all. Parsing a
# manifest into a JSON DOM and re-serializing it produces semantically identical
# JSON with a DIFFERENT digest, which would break every by-digest reference that
# points at it. So the copier parses manifests only to DISCOVER the descriptors
# it must follow, and PUTs the original bytes verbatim. This module never sees a
# DOM — it takes bytes, and only bytes.
#
# Reuses `komira_crypto.sha256` + `hex_lower_array_32`; it reinvents nothing.
# =============================================================================

from komira_crypto.sha256 import sha256
from komira_crypto.hex import hex_lower_array_32


def digest_of_bytes(data: Span[UInt8, _]) -> String:
    """Content-address `data` as an OCI digest string: `sha256:<64 lower hex>`.

    This is the canonical spelling used everywhere in the package, so a digest
    computed here is directly comparable (`==`) to a digest parsed out of a ref
    or a descriptor — no normalization step, no case folding, nothing to forget
    at a call site."""
    return String("sha256:") + hex_lower_array_32(sha256(data))


def validate_digest_format(digest: String, ctx: String) raises:
    """A digest MUST be `sha256:` + exactly 64 LOWERCASE hex characters.

    Checked wherever a digest ENTERS the package, because every downstream use of
    the value is an `==` comparison against a computed content-address: an
    unvalidated digest differing only in case or length compares unequal to the
    same content's real digest, and the copier would then report a "digest
    mismatch" for what is really a malformed input — sending the operator after
    a corruption that does not exist.

    `ctx` names where the digest came from (a ref, a layout file) so the error
    points at the thing to fix."""
    if not digest.startswith(String("sha256:")):
        raise Error(
            String("oci: unsupported digest algorithm in ")
            + ctx
            + String(" — only 'sha256:' is supported, got '")
            + digest
            + String("'")
        )
    var hex = String(digest[byte=7 : digest.byte_length()])
    if hex.byte_length() != 64:
        raise Error(
            String("oci: malformed digest in ")
            + ctx
            + String(" — a sha256 digest must be 64 hex chars, got ")
            + String(hex.byte_length())
        )
    for i in range(hex.byte_length()):
        var c = UInt8(ord(hex[byte=i]))
        var is_digit = c >= UInt8(48) and c <= UInt8(57)
        var is_lower_hex = c >= UInt8(97) and c <= UInt8(102)
        if not (is_digit or is_lower_hex):
            raise Error(
                String("oci: malformed digest in ")
                + ctx
                + String(
                    " — a sha256 digest must be LOWERCASE hex (a registry"
                    " content-address is case-sensitive), got '"
                )
                + digest
                + String("'")
            )


def verify_digest(data: Span[UInt8, _], expected: String, what: String) raises:
    """REFUSE unless `data` content-addresses to `expected`.

    ⚠ THIS RAISES — it does not return a Bool. That is deliberate: a Bool return
    is a check a caller can forget to read, and the failure mode of forgetting is
    that a corrupt or substituted artifact gets recorded as a deployable ref. A
    content-address violation has exactly one correct response — abort the copy —
    so the type system is used to make ignoring it impossible.

    `what` names the artifact in the error (e.g. `manifest sha256:…`,
    `blob sha256:…`) so an operator can tell a bad manifest from a bad layer."""
    var actual = digest_of_bytes(data)
    if actual != expected:
        raise Error(
            String("oci: DIGEST MISMATCH for ")
            + what
            + String(" — expected ")
            + expected
            + String(" but the ")
            + String(len(data))
            + String(
                " bytes received content-address to "
            )
            + actual
            + String(
                ". REFUSING the copy: a content-addressed promote whose bytes do"
                " not match their digest is either corruption in transit or a"
                " substituted artifact, and must never be recorded as a"
                " deployable ref."
            )
        )
